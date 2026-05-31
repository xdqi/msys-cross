#!/bin/bash
# patch-pacman-nonroot.sh — remove pacman's hard root requirement, in place.
#
# Usage: patch-pacman-nonroot.sh <pacman-static-binary>
#
# pacman gates installing operations on `if(myuid > 0 && needs_root())` in
# src/pacman/pacman.c main(). No CLI flag bypasses it for a real `-S` install
# (--root/--dbpath/-w do not help). We flip the `je` that skips the check when
# uid==0 into an unconditional `jmp`, so the check is always skipped — letting a
# non-root user install into a user-owned --root prefix (the msys2-cross bootstrap
# use case), with no fakeroot needed.
#
# The patch site is located by symbol + string xref (no hardcoded offset), so it
# survives archlinuxcn rebuilds as long as the binary keeps the needs_root symbol.
# It fails loudly if the site can't be uniquely identified.
set -euo pipefail

BIN="${1:?usage: patch-pacman-nonroot.sh <pacman-static-binary>}"
[ -f "$BIN" ] || { echo "ERROR: no such file: $BIN" >&2; exit 1; }

python3 - "$BIN" <<'PY'
import re, subprocess, sys

binpath = sys.argv[1]

def run(*cmd):
    return subprocess.check_output(cmd, text=True)

# 1) needs_root() virtual address from the symbol table (binary must be unstripped).
nm = run("nm", binpath)
m = re.search(r'^([0-9a-fA-F]+)\s+[Tt]\s+needs_root$', nm, re.M)
if not m:
    sys.exit("ERROR: 'needs_root' symbol not found — is the binary stripped?")
needs_root_va = int(m.group(1), 16)

# 2) Virtual address of the root-error string, mapped from its file offset.
strings_out = run("strings", "-t", "d", binpath)
sm = re.search(r'^\s*(\d+)\s+you cannot perform this operation unless you are root',
               strings_out, re.M)
if not sm:
    sys.exit("ERROR: root-error string not found in binary")
str_foff = int(sm.group(1))

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
str_va = file_off_to_va(str_foff)
if str_va is None:
    sys.exit("ERROR: could not map root-error string to a VA")

# 3) In main(), find the `call <needs_root>` whose 2nd-following insn lea's the
#    root-error string — that uniquely identifies the `if(myuid>0 && needs_root())`
#    guard (the other needs_root call site does not load this string). Back up to
#    the immediately preceding `je` (opcode 0x74) and flip it to jmp (0xeb).
asm = run("objdump", "-d", "--no-show-raw-insn", binpath).splitlines()
call_re = re.compile(r'^\s*([0-9a-f]+):\s+(?:addr32 )?call\s+%s\s+<needs_root>' %
                     format(needs_root_va, 'x'))
# The guard's conditional jump (`je`, opcode 0x74). On a re-run of an
# already-patched binary it reads back as an unconditional short `jmp` (0xeb),
# so match either — step 4 disambiguates at the byte level.
je_re   = re.compile(r'^\s*([0-9a-f]+):\s+(?:je|jmp)\s+(?:0x)?[0-9a-f]+')

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
je_va = sites[0]
foff = va_to_file_off(je_va)
if foff is None:
    sys.exit("ERROR: could not map patch VA 0x%x to a file offset" % je_va)

# 4) Apply: assert the byte is `je` (0x74), write `jmp` (0xeb).
with open(binpath, "r+b") as f:
    f.seek(foff)
    cur = f.read(1)
    if cur == b"\xeb":
        print("Already patched (0x%x = jmp); nothing to do." % foff)
        sys.exit(0)
    if cur != b"\x74":
        sys.exit("ERROR: unexpected byte 0x%02x at 0x%x (expected 0x74 je)"
                 % (cur[0], foff))
    f.seek(foff)
    f.write(b"\xeb")
print("Patched root check: je->jmp at file offset 0x%x (VA 0x%x)" % (foff, je_va))
PY
