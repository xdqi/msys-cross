# pacman Reuse build_deps zlib/zstd Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `msys-cross-pacman` reuse build_deps' prebuilt zlib/zstd instead of recompiling its own, dropping 2 of its 13 dep builds.

**Architecture:** `build_deps.sh` is extended so its zstd step installs `libzstd.pc` (zlib already installs `zlib.pc`). The pacman PKGBUILD hard-requires `deps/install`, copies the zlib/zstd `.a`+headers+`.pc` into the AUR build's `$srcdir/temp/usr`, and neutralizes the AUR `build()`'s own zlib/zstd compile blocks (awk range-delete on the inherited `_aur_build`, chained with the existing libarchive-CFLAGS sed). Consumers (curl/libarchive/pacman) are unchanged — they still find everything in `temp/usr`.

**Tech Stack:** bash/PKGBUILD (makepkg), `inherit_aur` (scripts/msys-cross-common.sh), zig cc, the AUR `pacman-static` build, zstd/zlib Makefiles, awk/sed function rewriting.

---

## File Structure

- **Modify** `scripts/build_deps.sh` — zstd step: replace manual `cp` with zstd's `install-pc install-static install-includes` so `deps/install/lib/pkgconfig/libzstd.pc` exists. (zlib unchanged; it already installs `zlib.pc`.)
- **Modify** `pkgs/msys-cross-pacman/PKGBUILD` — add a hard-require guard for `deps/install` zlib/zstd; in `build()`, seed `temp/usr` from `deps/install` and extend the existing `_aur_build` rewrite to neutralize the zstd/zlib compile blocks.

No new files. Both changes are small, in established files.

Verified facts (current tree):
- `scripts/build_deps.sh:119-123` is the zstd step (`cd $WORK_DEPS/zstd-$VER/lib; make libzstd.a; cp libzstd.a; cp headers`). `PREFIX=deps/install` (`:20`). zstd's `lib/Makefile` has `install-pc`/`install-static`/`install-includes` targets (the AUR build uses them).
- `pkgs/msys-cross-pacman/PKGBUILD` `build()` (`:67-83`) already does `eval "$(declare -f _aur_build | sed '<libarchive CFLAGS fix>')"; _aur_build`. `$_deps` = `deps/install` (from msys-cross-common.sh).
- Under `declare -f _aur_build`, the zstd block is the lines from `cd "${srcdir}"/zstd-${_zstdver}/lib;` up to (not incl.) `cd "${srcdir}"/brotli;`; the zlib block is from `cd "${srcdir}/"zlib-${_zlibver};` up to (not incl.) `cd "${srcdir}"/openssl-${_sslver};`. (Prototyped: an awk toggle keyed on these `cd` lines cleanly removes both blocks, leaves brotli/openssl intact, and re-`eval`s.)

---

## Task 1: build_deps.sh — zstd installs libzstd.pc

**Files:**
- Modify: `scripts/build_deps.sh:119-123` (the `=== zstd ===` block)

- [ ] **Step 1: Replace the zstd build/install commands**

Current (lines 119-123):
```sh
echo "=== zstd ==="
cd "$WORK_DEPS/zstd-${ZSTD_VER}/lib"
CFLAGS="-O2 -fPIC" make -j"$JOBS" libzstd.a
cp libzstd.a "$PREFIX/lib/"
cp zstd.h zdict.h zstd_errors.h "$PREFIX/include/"
```
Replace with (use zstd's own install targets so the `.pc` is produced — mirrors the AUR build, and keeps the static lib + headers):
```sh
echo "=== zstd ==="
cd "$WORK_DEPS/zstd-${ZSTD_VER}/lib"
CFLAGS="-O2 -fPIC" make -j"$JOBS" libzstd.a
# install-pc emits lib/pkgconfig/libzstd.pc (needed by pkg-config consumers such as
# the from-source pacman build); install-static + install-includes give libzstd.a +
# headers — same artifacts the old manual cp produced, plus the .pc.
make PREFIX="$PREFIX" install-pc install-static install-includes
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/build_deps.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify it actually produces libzstd.pc + libzstd.a**

This compiles only zstd into a throwaway prefix (fast). Run from the worktree root:
```bash
T=$(mktemp -d); SRC=$(mktemp -d)
ver=$(grep -E '^ZSTD_VER=' scripts/build_deps.sh | head -1 | sed 's/.*:-//; s/}.*//')
echo "zstd ver: $ver"
( cd "$SRC" && curl -fsSL "https://github.com/facebook/zstd/releases/download/v$ver/zstd-$ver.tar.gz" -o z.tgz && tar xf z.tgz && cd "zstd-$ver/lib" && CFLAGS="-O2 -fPIC" make -j"$(nproc)" libzstd.a >/dev/null 2>&1 && make PREFIX="$T" install-pc install-static install-includes >/dev/null 2>&1 )
echo "--- expect libzstd.a, headers, libzstd.pc ---"
ls "$T/lib/libzstd.a" "$T/include/zstd.h" "$T/lib/pkgconfig/libzstd.pc"
PKG_CONFIG_PATH="$T/lib/pkgconfig" pkg-config --modversion libzstd
rm -rf "$T" "$SRC"
```
Expected: all three files listed, and `pkg-config --modversion libzstd` prints the version (e.g. `1.5.7`). If network is blocked, note it and rely on Task 3's container build to validate.

- [ ] **Step 4: Commit**

```bash
git add scripts/build_deps.sh
git commit -m "build_deps: zstd installs libzstd.pc (install-pc) for pkg-config consumers"
```

---

## Task 2: pacman PKGBUILD — hard-require deps/install + reuse zlib/zstd

**Files:**
- Modify: `pkgs/msys-cross-pacman/PKGBUILD` — add a guard after `inherit_aur`/metadata; rewrite `build()`.

- [ ] **Step 1: Add the hard-require guard**

After the toolchain block (the `export CC CXX AR RANLIB` line at `:54`) and before `prepare()` (`:56`), insert:
```bash
# ---- Reuse build_deps' prebuilt zlib/zstd (HARD dependency on deps/install) ----
# pacman would otherwise recompile zlib+zstd that scripts/build_deps.sh already
# built into $_deps. We reuse those instead. In the full build.sh flow build_deps
# runs before this package; a standalone build of msys-cross-pacman MUST run
# scripts/build_deps.sh first. Fail loudly (not mid-build) if they're absent.
_require_builddeps_libs() {
    local missing=0 f
    for f in lib/libz.a lib/libzstd.a lib/pkgconfig/zlib.pc lib/pkgconfig/libzstd.pc \
             include/zlib.h include/zstd.h; do
        [ -e "$_deps/$f" ] || { echo "ERROR: $_deps/$f missing" >&2; missing=1; }
    done
    [ "$missing" -eq 0 ] || {
        echo "ERROR: build_deps zlib/zstd not found — run scripts/build_deps.sh first" >&2
        return 1
    }
}
```
(Defining a function here, called from build(), keeps the check at build time — the reliable gate — rather than only at PKGBUILD source time.)

- [ ] **Step 2: Rewrite build() to seed temp/usr and neutralize the AUR zlib/zstd blocks**

Replace the entire current `build()` (`:66-83`) with:
```bash
# ---- build(): reuse build_deps zlib/zstd, then the inherited AUR build ----
build() {
    _require_builddeps_libs

    # Seed $srcdir/temp/usr (the dir every AUR dep installs into) with build_deps'
    # zlib/zstd: static libs, headers, and pkg-config files. Consumers find them
    # here exactly as if the AUR had built them (curl via --with-zlib/zstd-*=temp/usr,
    # libarchive/pacman via PKG_CONFIG_PATH=temp/usr/lib/pkgconfig).
    local t="${srcdir}/temp/usr"
    mkdir -p "$t/lib/pkgconfig" "$t/include"
    cp -a "$_deps/lib/libz.a" "$_deps/lib/libzstd.a" "$t/lib/"
    cp -a "$_deps/include/zlib.h" "$_deps/include/zconf.h" "$t/include/"
    cp -a "$_deps/include/zstd.h" "$_deps/include/zdict.h" "$_deps/include/zstd_errors.h" "$t/include/"
    cp -a "$_deps/lib/pkgconfig/zlib.pc" "$_deps/lib/pkgconfig/libzstd.pc" "$t/lib/pkgconfig/"

    # Rewrite the inherited AUR build():
    #  (1) awk: drop its zstd block (cd zstd .. before cd brotli) and zlib block
    #      (cd zlib .. before cd openssl) — we supplied those from build_deps above.
    #      The blocks are delimited by the next dep's `cd "${srcdir}"/<dep>` line, which
    #      is stable under `declare -f`.
    #  (2) sed: the libarchive CFLAGS fix (re-add -O2 -fno-sanitize=undefined; zig cc
    #      defaults -fsanitize=undefined on, which the bare AUR CFLAGS override would
    #      otherwise leave at -O0 and pull 600+ __ubsan_* into the static link).
    eval "$(declare -f _aur_build \
        | awk '
            /cd "\$\{srcdir\}"\/zstd-\$\{_zstdver\}\/lib;/ { skip=1 }
            /cd "\$\{srcdir\}"\/brotli;/                   { skip=0 }
            /cd "\$\{srcdir\}\/"zlib-\$\{_zlibver\};/      { skip=1 }
            /cd "\$\{srcdir\}"\/openssl-\$\{_sslver\};/    { skip=0 }
            skip==0 { print }
          ' \
        | sed 's|CFLAGS="-L${srcdir}/temp/usr/lib"|CFLAGS="-L${srcdir}/temp/usr/lib -O2 -fno-sanitize=undefined"|')"

    # Guard: if a future AUR bump moves the zstd/zlib `cd` anchors, the awk silently
    # stops removing them — assert the blocks are actually gone so we fail loudly
    # rather than silently recompiling (or worse, mis-deleting).
    if declare -f _aur_build | grep -qE 'make libzstd\.a|make libz\.a'; then
        echo "ERROR: AUR zstd/zlib blocks not neutralized — anchors changed?" >&2
        return 1
    fi

    _aur_build
}
```

- [ ] **Step 3: Syntax-check the PKGBUILD**

Run: `bash -n pkgs/msys-cross-pacman/PKGBUILD && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify the rewrite logic in isolation (no full build)**

Confirm the guard + awk neutralization behave, using the same inherit machinery the PKGBUILD uses:
```bash
cd pkgs/msys-cross-pacman
bash -c '
  source ../../scripts/msys-cross-common.sh 2>/dev/null
  inherit_aur pacman-static 2>/dev/null
  rewritten=$(declare -f _aur_build \
    | awk '"'"'
        /cd "\$\{srcdir\}"\/zstd-\$\{_zstdver\}\/lib;/ { skip=1 }
        /cd "\$\{srcdir\}"\/brotli;/                   { skip=0 }
        /cd "\$\{srcdir\}\/"zlib-\$\{_zlibver\};/      { skip=1 }
        /cd "\$\{srcdir\}"\/openssl-\$\{_sslver\};/    { skip=0 }
        skip==0 { print }
      '"'"' \
    | sed '"'"'s|CFLAGS="-L${srcdir}/temp/usr/lib"|CFLAGS="-L${srcdir}/temp/usr/lib -O2 -fno-sanitize=undefined"|'"'"')
  echo "zstd/zlib build cmds remaining (expect 0): $(echo "$rewritten" | grep -cE "make libzstd\.a|make libz\.a")"
  echo "libarchive fix present (expect 1): $(echo "$rewritten" | grep -c "fno-sanitize=undefined")"
  echo "brotli present (expect >=1): $(echo "$rewritten" | grep -c "brotli")"
  echo "openssl present (expect >=1): $(echo "$rewritten" | grep -c "openssl-")"
  eval "$rewritten" && echo "re-eval OK"
'
```
Expected: `0`, `1`, `>=1`, `>=1`, and `re-eval OK`. (cd back to the worktree root afterward.)

- [ ] **Step 5: Commit**

```bash
cd /home/kosaka/msys2-cross/.claude/worktrees/pacman-from-source
git add pkgs/msys-cross-pacman/PKGBUILD
git commit -m "pacman: reuse build_deps zlib/zstd (seed temp/usr, neutralize AUR blocks)"
```

---

## Task 3: Full build + verification (Arch container)

**Files:** none (verification only)

The build must run in `archlinux/archlinux:base-devel` (Arch makepkg + pacman -S), like CI. This host is Debian; use `docker`. This task both validates the reuse and re-confirms the prior end-to-end behaviour is unchanged.

- [ ] **Step 1: Launch container + host tools + builduser**

```bash
docker rm -f pacreuse 2>/dev/null || true
docker run -d --name pacreuse \
  -v /home/kosaka/msys2-cross:/home/kosaka/msys2-cross \
  archlinux/archlinux:base-devel sleep infinity
docker exec pacreuse bash -c 'pacman -Syu --noconfirm --noprogressbar 2>&1 | tail -1'
docker exec pacreuse bash -c 'pacman -S --noconfirm --noprogressbar --needed base-devel curl git zstd sudo meson cmake gperf 2>&1 | tail -2'
docker exec pacreuse bash -c 'useradd -m builduser 2>/dev/null; echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers'
docker exec pacreuse bash -c 'git config --global --add safe.directory "*"'
docker exec -u builduser pacreuse bash -c 'git config --global --add safe.directory "*"'
```

- [ ] **Step 2: Prepare zig + run build_deps (so deps/install is populated, incl. libzstd.pc)**

```bash
WT=/home/kosaka/msys2-cross/.claude/worktrees/pacman-from-source
docker exec -u builduser pacreuse bash -c "cd $WT && bash scripts/prepare-zig.sh 2>&1 | tail -3"
docker exec -u builduser pacreuse bash -c "cd $WT && bash scripts/build_deps.sh 2>&1 | tail -6"
docker exec -u builduser pacreuse bash -c "ls $WT/deps/install/lib/libz.a $WT/deps/install/lib/libzstd.a $WT/deps/install/lib/pkgconfig/zlib.pc $WT/deps/install/lib/pkgconfig/libzstd.pc"
```
Expected: all four files listed (Task 1's `libzstd.pc` now present). If `build_deps.sh` needs network and it's blocked, that's a hard blocker for this verification — report it.

- [ ] **Step 3: Build msys-cross-pacman and confirm zlib/zstd were NOT recompiled**

```bash
WT=/home/kosaka/msys2-cross/.claude/worktrees/pacman-from-source
docker exec -u builduser pacreuse bash -c "cd $WT/pkgs/msys-cross-pacman && makepkg -fCd --skippgpcheck 2>&1" | tee /tmp/pacreuse-build.log | tail -50
echo "=== zlib/zstd should NOT have been compiled by the AUR build (expect 0 matches) ==="
grep -cE 'make libzstd\.a|make libz\.a|Compiling.*zstd|zlib-1\.3\.2/configure' /tmp/pacreuse-build.log || echo 0
echo "=== build still produced the package ==="
docker exec -u builduser pacreuse bash -c "ls -la $WT/pkgs/msys-cross-pacman/*.pkg.tar.* 2>/dev/null"
```
Expected: build succeeds, `check(): OK` lines present, package produced, and NO zlib/zstd compile lines. If a dep now fails because a header/`.pc` differs, capture the error from /tmp/pacreuse-build.log and report (do not thrash; max 2 small fixes).

- [ ] **Step 4: Re-confirm artifact + behaviour unchanged**

```bash
WT=/home/kosaka/msys2-cross/.claude/worktrees/pacman-from-source
docker exec pacreuse bash -c "cd /tmp && rm -rf chk && mkdir chk && cd chk && \
  tar -xf $WT/pkgs/msys-cross-pacman/*.pkg.tar.* && \
  echo '=== ldd (expect only libc/ld-linux/libm/libpthread/libdl/librt) ===' && ldd libexec/pacman-static && \
  echo '=== strings hookdir ===' && strings libexec/pacman-static | grep -E 'libalpm/(hooks|msys-cross-hooks)/'"
# Non-root -U behavioural test (same fixture as the prior task)
docker exec pacreuse bash -c '
set -e
WT=/home/kosaka/msys2-cross/.claude/worktrees/pacman-from-source
PFX=/tmp/pfx; rm -rf /tmp/pfx /tmp/HOOK_FIRED; mkdir -p "$PFX/libexec" "$PFX/bin" "$PFX/etc/pacman.d" "$PFX/var/lib/pacman"
P=$(ls $WT/pkgs/msys-cross-pacman/*.pkg.tar.*)
tar -xf "$P" -C "$PFX" libexec/pacman-static bin/msys-pacman etc/pacman.d/pacman.conf
chmod +x "$PFX/libexec/pacman-static" "$PFX/bin/msys-pacman"
printf "[options]\nArchitecture = x86_64\nNoExtract = *.exe\nSigLevel = Never\n" > "$PFX/etc/pacman.d/pacman.conf"
TP=/tmp/tp; rm -rf "$TP"; mkdir -p "$TP/usr/share/libalpm/hooks" "$TP/usr/bin" "$TP/opt"
echo data > "$TP/opt/testfile"; echo win > "$TP/usr/bin/evil.exe"
printf "[Trigger]\nType=Path\nOperation=Install\nTarget=opt/*\n[Action]\nWhen=PostTransaction\nExec=/bin/sh -c \"touch /tmp/HOOK_FIRED\"\n" > "$TP/usr/share/libalpm/hooks/zz.hook"
printf "pkgname=tp\npkgver=1.0-1\narch=x86_64\nsize=4\n" > "$TP/.PKGINFO"
( cd "$TP" && bsdtar --uid 0 --gid 0 -caf /tmp/tp-1.0-1-x86_64.pkg.tar.zst .PKGINFO usr opt )
chown -R builduser /tmp/pfx /tmp/tp-1.0-1-x86_64.pkg.tar.zst
sudo -u builduser "$PFX/bin/msys-pacman" -U /tmp/tp-1.0-1-x86_64.pkg.tar.zst --noconfirm 2>&1 | tail -3
echo "owner: $(stat -c %u $PFX/opt/testfile) (expect $(id -u builduser))"
[ -e "$PFX/usr/bin/evil.exe" ] && echo "exe: FAIL" || echo "exe: OK skipped"
[ -e /tmp/HOOK_FIRED ] && echo "hook: FAIL" || echo "hook: OK neutralized"
'
```
Expected: ldd shows only libc-family (mostly-static intact); hookdir = msys-cross-hooks; install succeeds; owner = builduser uid (not 0); exe skipped; hook neutralized — i.e. identical to the pre-reuse behaviour.

- [ ] **Step 5: Guard test — missing deps/install fails fast**

```bash
WT=/home/kosaka/msys2-cross/.claude/worktrees/pacman-from-source
docker exec -u builduser pacreuse bash -c "cd $WT && mv deps/install /tmp/install-bak && cd pkgs/msys-cross-pacman && makepkg -fCd --skippgpcheck 2>&1 | grep -iE 'run scripts/build_deps|missing' | head -3; cd $WT && mv /tmp/install-bak deps/install"
```
Expected: the "run scripts/build_deps.sh first" / "missing" error appears (fails fast, not a confusing mid-build error). Then deps/install is restored.

- [ ] **Step 6: Cleanup**

```bash
docker rm -f pacreuse
```
Commit nothing here unless Step 3 required a fix; if so, commit it with a clear message and report the SHA.

---

## Self-Review Notes

- **Spec coverage:** build_deps libzstd.pc (Task 1) ↔ spec change #1; hard-require guard (Task 2 Step 1) ↔ spec "hard dependency"; seed temp/usr (Task 2 Step 2) ↔ spec injection (b); awk-neutralize blocks + libarchive sed chain (Task 2 Step 2) ↔ spec injection (c); anchor-drift guard (Task 2 Step 2) ↔ spec Risk #1; build+verify+guard test (Task 3) ↔ spec Verification 1-4 and Risk #3. No version check (spec decision) — correctly absent.
- **No version check:** intentionally omitted per the user's decision; not a gap.
- **awk/sed mechanism** was prototyped against the live `declare -f _aur_build` before writing this plan (zstd+zlib blocks removed, brotli/openssl intact, libarchive fix survives, re-eval OK).
- **Source-list zlib/zstd downloads** left in place (spec: harmless, removing risks desyncing AUR source/sums) — no task, as designed.
