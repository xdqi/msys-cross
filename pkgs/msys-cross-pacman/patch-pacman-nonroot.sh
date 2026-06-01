#!/bin/bash
# patch-pacman-nonroot.sh — make pacman-static usable for an unprivileged,
# relocatable msys2-cross bootstrap prefix, by binary-patching three behaviours
# in place. Every patch site is located by symbol + string/xref (no hardcoded
# offsets), so it survives archlinuxcn rebuilds; each fails loudly if its site
# can't be uniquely identified, and is idempotent on a re-run.
#
# Usage: patch-pacman-nonroot.sh <pacman-static-binary>
#
# Patch A — drop the hard root requirement.
#   pacman gates installing operations on `if(myuid > 0 && needs_root())` in
#   src/pacman/pacman.c main(). No CLI flag bypasses it for a real `-S` install
#   (--root/--dbpath/-w do not help). We flip the `je` that skips the check when
#   uid==0 into an unconditional `jmp`, so the check is always skipped — letting a
#   non-root user install into a user-owned --root prefix with no fakeroot needed.
#
# Patch B — clear ARCHIVE_EXTRACT_OWNER.
#   libalpm's perform_extraction() (lib/libalpm/add.c) passes the flag constant
#   0x197 (= OWNER|PERM|TIME|UNLINK|XATTR|SECURE_SYMLINKS) to
#   archive_write_disk_set_options(). ARCHIVE_EXTRACT_OWNER (bit 0) chowns every
#   extracted file to the package's authored uid/gid (0:0); libalpm exposes no
#   config/CLI/env to disable it, and the MSYS2 __MSYS__ guard is not active in
#   this archlinuxcn musl build. We rewrite the immediate 0x197 -> 0x196 (clear
#   bit 0). The other five flags are all non-root-safe.
#
# Patch C — redirect the system alpm hook dir to an empty path.
#   libalpm ALWAYS reads the system hook dir and rebases it onto RootDir
#   (lib/libalpm/alpm.c: sprintf(hookdir,"%s%s",handle->root,&SYSHOOKDIR[1])), so
#   a package that installs $PREFIX/usr/share/libalpm/hooks/*.hook would have that
#   hook Exec'd under chroot during the transaction — e.g. MSYS2 rebase.hook ->
#   /usr/bin/rebase, texinfo -> install-info.exe — on the Linux bootstrap host.
#   --hookdir/HookDir is purely additive and cannot disable the system dir, so we
#   overwrite the SYSHOOKDIR string "/usr/share/libalpm/hooks/" in place with a
#   same-length inert path "/usr/share/libalpm/.nope/". The rebased system hook
#   dir is then always empty (admin hooks still work via --hookdir).
set -euo pipefail

BIN="${1:?usage: patch-pacman-nonroot.sh <pacman-static-binary>}"
[ -f "$BIN" ] || { echo "ERROR: no such file: $BIN" >&2; exit 1; }

python3 - "$BIN" <<'PY'
import re, subprocess, sys

binpath = sys.argv[1]

def run(*cmd):
    return subprocess.check_output(cmd, text=True)

# Section table, parsed once, used by the VA<->file-offset helpers below.
sections = run("readelf", "-S", "-W", binpath)

def file_off_to_va(foff):
    for line in sections.splitlines():
        mm = re.search(r'\]\s+\.\S+\s+\w+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)', line)
        if mm:
            va, fo, sz = (int(mm.group(i), 16) for i in (1, 2, 3))
            if va and fo <= foff < fo + sz:
                return va + (foff - fo)
    return None

def va_to_file_off(va):
    for line in sections.splitlines():
        mm = re.search(r'\]\s+\.\S+\s+\w+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)', line)
        if mm:
            sva, fo, sz = (int(mm.group(i), 16) for i in (1, 2, 3))
            if sva and sva <= va < sva + sz:
                return fo + (va - sva)
    return None

def sym_va(name, kind=r'[Tt]'):
    """Virtual address of a symbol from the symbol table (binary must be unstripped)."""
    nm = run("nm", binpath)
    m = re.search(r'^([0-9a-fA-F]+)\s+%s\s+%s$' % (kind, re.escape(name)), nm, re.M)
    return int(m.group(1), 16) if m else None


# ---------------------------------------------------------------------------
# Patch A — root check je -> jmp
# ---------------------------------------------------------------------------
def patch_root_check():
    needs_root_va = sym_va("needs_root")
    if needs_root_va is None:
        sys.exit("ERROR: 'needs_root' symbol not found — is the binary stripped?")

    # Virtual address of the root-error string, mapped from its file offset.
    strings_out = run("strings", "-t", "d", binpath)
    sm = re.search(r'^\s*(\d+)\s+you cannot perform this operation unless you are root',
                   strings_out, re.M)
    if not sm:
        sys.exit("ERROR: root-error string not found in binary")
    str_va = file_off_to_va(int(sm.group(1)))
    if str_va is None:
        sys.exit("ERROR: could not map root-error string to a VA")

    # In main(), find the `call <needs_root>` whose 2nd-following insn lea's the
    # root-error string — that uniquely identifies the `if(myuid>0 && needs_root())`
    # guard. Back up to the immediately preceding `je` (0x74) and flip it to jmp.
    asm = run("objdump", "-d", "--no-show-raw-insn", binpath).splitlines()
    call_re = re.compile(r'^\s*([0-9a-f]+):\s+(?:addr32 )?call\s+%s\s+<needs_root>' %
                         format(needs_root_va, 'x'))
    # On a re-run of an already-patched binary the je reads back as jmp (0xeb),
    # so match either — the byte-level step below disambiguates.
    je_re = re.compile(r'^\s*([0-9a-f]+):\s+(?:je|jmp)\s+(?:0x)?[0-9a-f]+')

    sites = []
    for i, line in enumerate(asm):
        if not call_re.match(line):
            continue
        window = "\n".join(asm[i:i+4])
        if ('# %x' % str_va) not in window and ('0x%x' % str_va) not in window:
            continue                      # not the root-check call site
        for j in range(i - 1, max(i - 6, -1), -1):
            jm = je_re.match(asm[j])
            if jm:
                sites.append(int(jm.group(1), 16))
                break

    if len(sites) != 1:
        sys.exit("ERROR: expected exactly 1 root-check patch site, found %d %s"
                 % (len(sites), [hex(s) for s in sites]))
    foff = va_to_file_off(sites[0])
    if foff is None:
        sys.exit("ERROR: could not map root-check VA 0x%x to a file offset" % sites[0])

    with open(binpath, "r+b") as f:
        f.seek(foff)
        cur = f.read(1)
        if cur == b"\xeb":
            print("Patch A (root check): already patched (0x%x = jmp); skipping." % foff)
            return
        if cur != b"\x74":
            sys.exit("ERROR: unexpected byte 0x%02x at 0x%x (expected 0x74 je)"
                     % (cur[0], foff))
        f.seek(foff)
        f.write(b"\xeb")
    print("Patch A (root check): je->jmp at file offset 0x%x (VA 0x%x)" % (foff, sites[0]))


# ---------------------------------------------------------------------------
# Patch B — clear ARCHIVE_EXTRACT_OWNER (extract flags 0x197 -> 0x196)
# ---------------------------------------------------------------------------
def patch_extract_owner():
    awdso_va = sym_va("archive_write_disk_set_options", kind=r'[Tt]')
    if awdso_va is None:
        sys.exit("ERROR: 'archive_write_disk_set_options' symbol not found — stripped?")

    # Find the `mov $0x197,<reg>` whose nearby insn `call`s
    # archive_write_disk_set_options. The raw `be 97 01 00 00` byte sequence is
    # NOT unique in the file (it recurs ~9x as unrelated data/code), so we MUST
    # disambiguate via the call xref rather than a raw byte search.
    asm = run("objdump", "-d", "--no-show-raw-insn", binpath).splitlines()
    call_re = re.compile(r'^\s*([0-9a-f]+):\s+(?:addr32 )?call\s+%s\s+<archive_write_disk_set_options>' %
                         format(awdso_va, 'x'))
    # mov of the flag immediate into a register; on a re-run it reads 0x196.
    mov_re = re.compile(r'^\s*([0-9a-f]+):\s+mov\s+\$0x19[67],%\w+')

    sites = []
    for i, line in enumerate(asm):
        if not call_re.match(line):
            continue
        # The immediate is loaded shortly before the call; scan the preceding insns.
        for j in range(i - 1, max(i - 6, -1), -1):
            mm = mov_re.match(asm[j])
            if mm:
                sites.append(int(mm.group(1), 16))
                break

    if len(sites) != 1:
        sys.exit("ERROR: expected exactly 1 extract-flags patch site, found %d %s"
                 % (len(sites), [hex(s) for s in sites]))
    mov_va = sites[0]
    foff = va_to_file_off(mov_va)
    if foff is None:
        sys.exit("ERROR: could not map extract-flags VA 0x%x to a file offset" % mov_va)

    # The mov opcode is 1 byte (e.g. 0xbe for mov $imm32,%esi); the imm32 follows
    # little-endian as `97 01 00 00`. We patch the low byte (97 -> 96) which sits
    # at foff+1. Assert the surrounding immediate bytes to be certain we hit it.
    with open(binpath, "r+b") as f:
        f.seek(foff)
        op = f.read(5)            # opcode + imm32
        imm = op[1:5]
        if imm == b"\x96\x01\x00\x00":
            print("Patch B (extract owner): already patched (0x%x = 0x196); skipping." % foff)
            return
        if imm != b"\x97\x01\x00\x00":
            sys.exit("ERROR: unexpected immediate %s at 0x%x (expected 97 01 00 00)"
                     % (imm.hex(' '), foff + 1))
        f.seek(foff + 1)
        f.write(b"\x96")          # 0x197 -> 0x196 : clear ARCHIVE_EXTRACT_OWNER
    print("Patch B (extract owner): 0x197->0x196 at file offset 0x%x (VA 0x%x)"
          % (foff + 1, mov_va))


# ---------------------------------------------------------------------------
# Patch C — redirect SYSHOOKDIR string to an inert same-length path
# ---------------------------------------------------------------------------
def patch_syshookdir():
    OLD = b"/usr/share/libalpm/hooks/"   # 25 bytes, NUL-terminated in .rodata
    NEW = b"/usr/share/libalpm/.nope/"   # same length; dir packages never create
    assert len(OLD) == len(NEW), "replacement must be the same length"

    data = open(binpath, "rb").read()
    old_hits = [m.start() for m in re.finditer(re.escape(OLD + b"\x00"), data)]
    new_hits = [m.start() for m in re.finditer(re.escape(NEW + b"\x00"), data)]

    if not old_hits:
        if len(new_hits) == 1:
            print("Patch C (syshookdir): already patched (.nope present); skipping.")
            return
        sys.exit("ERROR: SYSHOOKDIR string '/usr/share/libalpm/hooks/' not found")
    if len(old_hits) != 1:
        sys.exit("ERROR: expected exactly 1 SYSHOOKDIR string, found %d %s"
                 % (len(old_hits), [hex(h) for h in old_hits]))

    foff = old_hits[0]
    with open(binpath, "r+b") as f:
        f.seek(foff)
        cur = f.read(len(OLD))
        if cur != OLD:
            sys.exit("ERROR: unexpected bytes at SYSHOOKDIR offset 0x%x" % foff)
        f.seek(foff)
        f.write(NEW)
    print("Patch C (syshookdir): '%s' -> '%s' at file offset 0x%x"
          % (OLD.decode(), NEW.decode(), foff))


patch_root_check()
patch_extract_owner()
patch_syshookdir()
PY
