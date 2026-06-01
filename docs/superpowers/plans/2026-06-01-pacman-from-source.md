# pacman-static From Source (zig-cc-gnu.2.11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the download-and-binary-patch `msys-cross-pacman` package with a from-source build that inherits the AUR `pacman-static` PKGBUILD, compiles with the repo's `zig cc` (target `x86_64-linux-gnu.2.11`, mostly-static), applies the three fixes (non-root / no-chown / no-Windows-hook) as **source patches**, and packages only the `pacman-static` binary plus the wrapper and config.

**Architecture:** Mirror `pkgs/msys-cross-cygwin-gcc`'s inherit-and-override model. A new `inherit_aur` helper in `scripts/msys-cross-common.sh` sources `deps/pacman-static/PKGBUILD` and saves its `prepare`/`build`/`package` as `_aur_*`. The reworked `pkgs/msys-cross-pacman/PKGBUILD` re-exports `CC=zigcc` + mostly-static `LDFLAGS` (the AUR sets `CC=musl-gcc`/`-static` at top level, so re-export wins), wraps `prepare()` to apply 3 source patches, and overrides `package()` to extract only the binary. `patch-pacman-nonroot.sh` is deleted.

**Tech Stack:** bash/PKGBUILD (makepkg), zig cc (`scripts/zigcc`, target gnu.2.11), meson (pacman), the AUR `pacman-static` dep-build sequence (curl/openssl/libarchive/gpgme/libseccomp/...), git submodule `deps/pacman-static`.

---

## File Structure

- **Create** `scripts/msys-cross-common.sh` → add `inherit_aur()` (alongside existing `inherit_msys2()`).
- **Create** `pkgs/msys-cross-pacman/0001-nonroot-allow-install.patch` — neutralize the root gate in `src/pacman/pacman.c`.
- **Create** `pkgs/msys-cross-pacman/0002-no-extract-owner.patch` — drop `ARCHIVE_EXTRACT_OWNER` in `lib/libalpm/add.c`.
- **Create** `pkgs/msys-cross-pacman/0003-syshookdir-msys-cross.patch` — rename system hook dir in `meson.build`.
- **Rewrite** `pkgs/msys-cross-pacman/PKGBUILD` — inherit AUR, re-export toolchain, prepare()/package() overrides, check().
- **Delete** `pkgs/msys-cross-pacman/patch-pacman-nonroot.sh`.
- **Unchanged** `pkgs/msys-cross-pacman/msys-pacman` (wrapper) and `pacman.conf` (from commit 88ba214).

Reference facts (verified at pacman commit `54d94116164b0b2202c6061c4a59c6f3e70820d8`, the pacman-static patch-level ref):
- `src/pacman/pacman.c:1226` → `if(myuid > 0 && needs_root()) {`
- `lib/libalpm/add.c:118-123` → `const int archive_flags = ARCHIVE_EXTRACT_OWNER | ... | ARCHIVE_EXTRACT_SECURE_SYMLINKS;`
- `meson.build:71` → `conf.set_quoted('SYSHOOKDIR', join_paths(DATAROOTDIR, 'libalpm/hooks/'))` AND `meson.build:455` → `join_paths(DATAROOTDIR, 'libalpm/hooks/'),` (mkdir-install loop). Both must change.

---

## Task 1: Add `inherit_aur` helper

**Files:**
- Modify: `scripts/msys-cross-common.sh` (append a new function after `inherit_msys2`, ~line 66)

- [ ] **Step 1: Add the `inherit_aur` function**

Insert after the closing `}` of `inherit_msys2` (currently line 66), before the `setup_zig_env` comment block:

```bash
# AUR package source root (submodule under deps/<name>).
_aur_root="${AUR_PACKAGES:-$_project_root/deps}"

inherit_aur() {
    # $1 = AUR package dir name under deps/ (e.g. "pacman-static")
    local _aur_dir="$_aur_root/$1"
    local _aur_pkgbuild="$_aur_dir/PKGBUILD"

    # Source the raw AUR PKGBUILD. Its top-level body sets CC=musl-gcc and
    # LDFLAGS=-static; the caller re-exports CC/LDFLAGS AFTER this returns, so the
    # caller's values win (build() reads ${CC}/${LDFLAGS} at call time).
    source "$_aur_pkgbuild"

    # Drop Arch makedepends/pgp checks we don't honor in this repo.
    makedepends=()
    validpgpkeys=()
    for i in "${!sha512sums[@]}"; do sha512sums[$i]='SKIP'; done
    [ -n "${sha256sums+x}" ] && for i in "${!sha256sums[@]}"; do sha256sums[$i]='SKIP'; done

    # Local (non-URL) source entries become file:// against the AUR dir so makepkg
    # finds the vendored patches/keys.
    for i in "${!source[@]}"; do
        case "${source[$i]}" in
            *://*) ;;
            *) source[$i]="file://$_aur_dir/${source[$i]}" ;;
        esac
    done

    # Save the AUR functions for chaining/overriding.
    eval "$(declare -f prepare 2>/dev/null | sed 's/^prepare /_aur_prepare /' || echo '_aur_prepare() { true; }')"
    eval "$(declare -f build   2>/dev/null | sed 's/^build /_aur_build /'     || echo '_aur_build() { true; }')"
    eval "$(declare -f package 2>/dev/null | sed 's/^package /_aur_package /' || echo '_aur_package() { true; }')"
}
```

- [ ] **Step 2: Syntax-check the helper sources cleanly**

Run: `bash -n scripts/msys-cross-common.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify it parses the AUR PKGBUILD and captures functions**

Run:
```bash
cd pkgs/msys-cross-pacman
bash -c 'source ../../scripts/msys-cross-common.sh; inherit_aur pacman-static; \
  declare -f _aur_build >/dev/null && echo "build OK"; \
  declare -f _aur_package >/dev/null && echo "package OK"; \
  echo "pkgver=$pkgver source0=${source[0]}"'
```
Expected: `build OK`, `package OK`, and a `pkgver=7.1.0...` line with the pacman git source as `source0`.

- [ ] **Step 4: Commit**

```bash
git add scripts/msys-cross-common.sh
git commit -m "build: add inherit_aur helper (mirror inherit_msys2 for AUR submodules)"
```

---

## Task 2: Source patch — allow non-root install

**Files:**
- Create: `pkgs/msys-cross-pacman/0001-nonroot-allow-install.patch`

- [ ] **Step 1: Write the patch**

Neutralize the `myuid > 0 && needs_root()` gate so a non-root `-S`/`-U` into a user-owned `--root` proceeds. Patch the `main()` condition (not `needs_root()` itself — there is a second unrelated caller at pacman.c:1325).

```diff
--- a/src/pacman/pacman.c
+++ b/src/pacman/pacman.c
@@ -1223,7 +1223,11 @@
 	}
 
 	/* check if we have sufficient permission for the requested operation */
-	if(myuid > 0 && needs_root()) {
+	/* msys2-cross: this static pacman installs into a user-owned, relocatable
+	 * --root prefix without privilege escalation, so the root gate is dropped.
+	 * Extraction is also patched to not chown (see add.c), so non-root install
+	 * is fully functional. */
+	if(0 && myuid > 0 && needs_root()) {
 		pm_printf(ALPM_LOG_ERROR, _("you cannot perform this operation unless you are root.\n"));
 		cleanup(EXIT_FAILURE);
 	}
```

- [ ] **Step 2: Verify the patch is well-formed**

Run: `cd pkgs/msys-cross-pacman && git apply --check --recount 0001-nonroot-allow-install.patch 2>&1 || echo "NOTE: no pacman tree here; structural check only"`
Expected: either silence (if a pacman tree is present) or the NOTE — the real apply is exercised in Task 6. Confirm the file has valid unified-diff syntax: `head -1 0001-nonroot-allow-install.patch` shows `--- a/src/pacman/pacman.c`.

- [ ] **Step 3: Commit**

```bash
git add pkgs/msys-cross-pacman/0001-nonroot-allow-install.patch
git commit -m "pacman(src): patch out non-root install gate (replaces binary je->jmp)"
```

---

## Task 3: Source patch — no chown on extraction

**Files:**
- Create: `pkgs/msys-cross-pacman/0002-no-extract-owner.patch`

- [ ] **Step 1: Write the patch**

Drop `ARCHIVE_EXTRACT_OWNER` (the chown-causing flag) from `perform_extraction()`'s flag list; keep the other five (all non-root-safe). The continuation lines use a tab + alignment spaces — match exactly.

```diff
--- a/lib/libalpm/add.c
+++ b/lib/libalpm/add.c
@@ -115,8 +115,11 @@
 	int ret;
 	struct archive *archive_writer;
-	const int archive_flags = ARCHIVE_EXTRACT_OWNER |
-	                          ARCHIVE_EXTRACT_PERM |
+	/* msys2-cross: ARCHIVE_EXTRACT_OWNER chowns every extracted file to the
+	 * package's authored uid/gid (0:0), which fails or wrongly roots files on a
+	 * non-root user-owned prefix. Dropped; the remaining flags are non-root-safe. */
+	const int archive_flags = ARCHIVE_EXTRACT_PERM |
 	                          ARCHIVE_EXTRACT_TIME |
 	                          ARCHIVE_EXTRACT_UNLINK |
 	                          ARCHIVE_EXTRACT_XATTR |
 	                          ARCHIVE_EXTRACT_SECURE_SYMLINKS;
```

- [ ] **Step 2: Verify unified-diff syntax**

Run: `head -1 pkgs/msys-cross-pacman/0002-no-extract-owner.patch`
Expected: `--- a/lib/libalpm/add.c`. (Real apply exercised in Task 6.)

- [ ] **Step 3: Commit**

```bash
git add pkgs/msys-cross-pacman/0002-no-extract-owner.patch
git commit -m "pacman(src): drop ARCHIVE_EXTRACT_OWNER (replaces binary 0x197->0x196)"
```

---

## Task 4: Source patch — redirect system hook dir

**Files:**
- Create: `pkgs/msys-cross-pacman/0003-syshookdir-msys-cross.patch`

- [ ] **Step 1: Write the patch**

Rename the system hook dir from `libalpm/hooks/` to `libalpm/msys-cross-hooks/` in BOTH meson.build occurrences (the `SYSHOOKDIR` define the binary scans, line 71; and the mkdir-install loop, line 455). Packages drop hooks into `usr/share/libalpm/hooks/`, which the binary no longer scans → no MSYS2/Windows package hook Execs on the Linux host. Admin hooks still work via the wrapper's `--hookdir`.

```diff
--- a/meson.build
+++ b/meson.build
@@ -68,7 +68,7 @@
-conf.set_quoted('SYSHOOKDIR', join_paths(DATAROOTDIR, 'libalpm/hooks/'))
+conf.set_quoted('SYSHOOKDIR', join_paths(DATAROOTDIR, 'libalpm/msys-cross-hooks/'))
@@ -452,7 +452,7 @@
 	join_paths(LOCALSTATEDIR, 'lib/pacman/'),
 	join_paths(LOCALSTATEDIR, 'cache/pacman/pkg/'),
 	join_paths(DATAROOTDIR, 'makepkg-template/'),
-	join_paths(DATAROOTDIR, 'libalpm/hooks/'),
+	join_paths(DATAROOTDIR, 'libalpm/msys-cross-hooks/'),
 	]
```

(The `@@` line numbers are hints; makepkg's `patch -Np1` applies by context, so minor upstream drift is tolerated. If a future pacman bump moves these, regenerate from the two `'libalpm/hooks/'` matches in meson.build.)

- [ ] **Step 2: Verify unified-diff syntax**

Run: `grep -c "msys-cross-hooks" pkgs/msys-cross-pacman/0003-syshookdir-msys-cross.patch`
Expected: `2` (both occurrences renamed).

- [ ] **Step 3: Commit**

```bash
git add pkgs/msys-cross-pacman/0003-syshookdir-msys-cross.patch
git commit -m "pacman(src): redirect system hook dir to msys-cross-hooks (replaces binary .nope)"
```

---

## Task 5: Rewrite the PKGBUILD (inherit + toolchain re-export + overrides)

**Files:**
- Modify (full rewrite): `pkgs/msys-cross-pacman/PKGBUILD`
- Delete: `pkgs/msys-cross-pacman/patch-pacman-nonroot.sh`

- [ ] **Step 1: Replace PKGBUILD contents**

```bash
# Maintainer: msys2-cross project
_startdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_startdir/../../scripts/msys-cross-common.sh"

# Inherit the AUR pacman-static PKGBUILD (deps/pacman-static submodule): its
# source=() / sha512sums / version vars and its prepare()/build()/package() (saved
# as _aur_*). It builds pacman + ~13 static deps (curl, openssl, libarchive,
# gpgme, libseccomp, ...) from source.
inherit_aur "pacman-static"

# ---- Package metadata (override the inherited AUR identity) ----
pkgname=msys-cross-pacman
pkgdesc="Static, source-patched pacman (non-root) + wrapper for msys2-cross bootstrap"
_our_pkgrel=1
pkgrel="${pkgrel}.${_our_pkgrel}"   # AUR pkgrel . ours
arch=('x86_64')
depends=('msys-cross-filesystem' 'msys-cross-ca-certificates')
backup=('etc/pacman.d/pacman.conf')
options=('!emptydirs' '!lto' '!strip')   # keep AUR !emptydirs/!lto; static binary, don't strip-split

# ---- Our additions to source[]: 3 pacman source patches + wrapper/conf ----
source+=("file://$_startdir/0001-nonroot-allow-install.patch"
         "file://$_startdir/0002-no-extract-owner.patch"
         "file://$_startdir/0003-syshookdir-msys-cross.patch"
         "file://$_startdir/msys-pacman"
         "file://$_startdir/pacman.conf")
sha512sums+=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')

# ---- Toolchain: zig cc target gnu.2.11, mostly-static ----
# Re-export AFTER inherit_aur so we override the AUR's top-level CC=musl-gcc /
# LDFLAGS=-static. build() reads ${CC}/${LDFLAGS} at call time, so these win.
setup_zig_env
# setup_zig_env's LDFLAGS pulls in gmp/mpfr/... which pacman's deps don't need;
# reset to a clean mostly-static default (the AUR build adds its own per-dep -L/-l).
export LDFLAGS="-Wl,-Bdynamic"
# Make CC a single token usable in the AUR build()'s `sed s|CC=gcc|CC=${CC}|`.
export CC CXX AR RANLIB

# ---- prepare(): AUR prepare + our 3 source patches ----
prepare() {
    _aur_prepare
    cd "${srcdir}/pacman"
    for p in 0001-nonroot-allow-install 0002-no-extract-owner 0003-syshookdir-msys-cross; do
        msg2 "Applying ${p}.patch"
        patch -Np1 -i "${srcdir}/${p}.patch"
    done
}

# ---- build(): inherited AUR build, with our CC/LDFLAGS already exported ----
build() {
    _aur_build
}

# ---- check(): behavioural assertions on the source-patched binary (non-root) ----
check() {
    [ "$(id -u)" -ne 0 ] || { echo "check(): refusing to validate as root"; return 1; }
    local bin="${srcdir}/pacman/build/pacman"
    [ -x "$bin" ] || bin="${srcdir}/pacman/build/src/pacman/pacman"
    [ -x "$bin" ] || { echo "check(): pacman binary not found under build/"; return 1; }

    # Non-root gate removed: a real -Sy must NOT print the root error.
    local root="${srcdir}/_checkroot"
    rm -rf "$root"; mkdir -p "$root/var/lib/pacman"
    cat > "$root/pacman.conf" <<'EOF'
[options]
Architecture = x86_64
SigLevel = Never
[core]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
    local out
    out=$("$bin" --root "$root" --config "$root/pacman.conf" \
        --dbpath "$root/var/lib/pacman" --noconfirm -Sy 2>&1) || true
    echo "$out"
    if grep -qi 'unless you are root' <<<"$out"; then
        echo "check(): FAILED — non-root gate still present" >&2; return 1
    fi
    echo "check(): OK — non-root gate removed"

    # No-chown: the source must no longer request ARCHIVE_EXTRACT_OWNER.
    if grep -q 'ARCHIVE_EXTRACT_OWNER' "${srcdir}/pacman/lib/libalpm/add.c"; then
        echo "check(): FAILED — ARCHIVE_EXTRACT_OWNER still present in add.c" >&2; return 1
    fi
    echo "check(): OK — extract-owner flag removed"

    # Hook dir redirected: binary must reference msys-cross-hooks, not the bare hooks dir.
    if ! strings "$bin" | grep -qF 'libalpm/msys-cross-hooks/'; then
        echo "check(): FAILED — msys-cross-hooks not in binary" >&2; return 1
    fi
    if strings "$bin" | grep -qE 'libalpm/hooks/$'; then
        echo "check(): FAILED — original system hook dir still present" >&2; return 1
    fi
    echo "check(): OK — system hook dir redirected to msys-cross-hooks"
}

# ---- package(): extract ONLY the pacman-static binary + wrapper + conf ----
package() {
    # The AUR build leaves the linked binary at pacman/build/src/pacman/pacman.
    local _pac="${srcdir}/pacman/build/src/pacman/pacman"
    [ -x "$_pac" ] || _pac="${srcdir}/pacman/build/pacman"

    install -Dm755 "$_pac"                       "$pkgdir/libexec/pacman-static"
    install -Dm755 "$srcdir/msys-pacman"         "$pkgdir/bin/msys-pacman"
    install -Dm644 "$srcdir/pacman.conf"         "$pkgdir/etc/pacman.d/pacman.conf"
}
```

- [ ] **Step 2: Delete the obsolete binary-patch script**

```bash
git rm pkgs/msys-cross-pacman/patch-pacman-nonroot.sh
```

- [ ] **Step 3: Syntax-check the PKGBUILD**

Run: `bash -n pkgs/msys-cross-pacman/PKGBUILD && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify metadata resolves (packagelist dry-run, no build)**

Run:
```bash
cd pkgs/msys-cross-pacman && makepkg --packagelist 2>/dev/null | tail -2
```
Expected: a single line ending in `msys-cross-pacman-7.1.0...-<pkgrel>-x86_64.pkg.tar.*`. (If makepkg complains about missing build dirs, that's fine for the name check; the real build is Task 6.)

- [ ] **Step 5: Commit**

```bash
git add pkgs/msys-cross-pacman/PKGBUILD
git commit -m "pacman: build from source (inherit AUR, zig-cc-gnu.2.11), drop binary patch"
```

---

## Task 6: Full build + behavioural verification

**Files:** none (verification only)

- [ ] **Step 1: Build the package via the repo driver**

Run (from the worktree root, as the build expects the unprivileged makepkg flow):
```bash
bash scripts/build_packages.sh msys-cross-pacman -fCd --skippgpcheck 2>&1 | tee /tmp/pacman-build.log | tail -40
```
Expected: the AUR dep sequence compiles under `zigcc` (watch for openssl/gpgme/libseccomp), `check(): OK` lines for all three patches, and a built `msys-cross-pacman-*.pkg.tar.*`. If a dep fails to compile under zig cc, capture the error — Risk #1 in the spec (per-dep flag tweaks) is where to iterate.

- [ ] **Step 2: Confirm the artifact is mostly-static (glibc dynamic)**

Run:
```bash
pkg=$(ls /home/kosaka/msys2-cross/repo/*/msys-cross-pacman-*.pkg.tar.* 2>/dev/null | head -1 || ls ./*.pkg.tar.* | head -1)
mkdir -p /tmp/pacchk && bsdtar -xf "$pkg" -C /tmp/pacchk libexec/pacman-static
file /tmp/pacchk/libexec/pacman-static
ldd /tmp/pacchk/libexec/pacman-static 2>&1 | head
```
Expected: `file` reports a dynamically-linked ELF with interpreter `/lib64/ld-linux-x86-64.so.2`; `ldd` shows ONLY `libc.so.6` / `ld-linux` (+ maybe libm/libpthread/libdl), NOT libcurl/libssl/libarchive (those are static).

- [ ] **Step 3: Behavioural test — non-root install, no chown, hook neutralized**

Run:
```bash
PFX=/tmp/pacbeh/prefix; rm -rf /tmp/pacbeh; mkdir -p "$PFX/libexec" "$PFX/bin" "$PFX/etc/pacman.d" "$PFX/var/lib/pacman" "$PFX/etc/ssl/certs"
bsdtar -xf "$pkg" -C "$PFX" --strip-components=0 libexec/pacman-static bin/msys-pacman etc/pacman.d/pacman.conf 2>/dev/null || {
  cp /tmp/pacchk/libexec/pacman-static "$PFX/libexec/"; cp pkgs/msys-cross-pacman/msys-pacman "$PFX/bin/"; }
chmod +x "$PFX/bin/msys-pacman" "$PFX/libexec/pacman-static"
# Build a root-authored test package with a hook + a .exe
TP=/tmp/pacbeh/tp; mkdir -p "$TP/usr/share/libalpm/hooks" "$TP/usr/bin" "$TP/opt"
echo data > "$TP/opt/testfile"; echo win > "$TP/usr/bin/evil.exe"
printf '[Trigger]\nType=Path\nOperation=Install\nTarget=opt/*\n[Action]\nWhen=PostTransaction\nExec=/bin/sh -c "touch /tmp/pacbeh/HOOK_FIRED"\n' > "$TP/usr/share/libalpm/hooks/zz.hook"
printf 'pkgname=tp\npkgver=1.0-1\narch=x86_64\nsize=4\n' > "$TP/.PKGINFO"
( cd "$TP" && bsdtar --uid 0 --gid 0 -caf /tmp/pacbeh/tp-1.0-1-x86_64.pkg.tar.zst .PKGINFO usr opt )
cat > "$PFX/etc/pacman.d/pacman.conf" <<'EOF'
[options]
Architecture = x86_64
NoExtract = *.exe
SigLevel = Never
EOF
rm -f /tmp/pacbeh/HOOK_FIRED
"$PFX/bin/msys-pacman" -U /tmp/pacbeh/tp-1.0-1-x86_64.pkg.tar.zst --noconfirm 2>&1 | tail -5
echo "owner: $(stat -c %u "$PFX/opt/testfile")  (expect $(id -u))"
[ -e "$PFX/usr/bin/evil.exe" ] && echo "exe: FAIL extracted" || echo "exe: OK skipped"
[ -e /tmp/pacbeh/HOOK_FIRED ] && echo "hook: FAIL fired" || echo "hook: OK neutralized"
```
Expected: install succeeds; `owner:` equals your uid (NOT 0); `exe: OK skipped`; `hook: OK neutralized`.

- [ ] **Step 4: End-to-end toolchain install (optional, network-dependent)**

Run: `bash scripts/test-docker.sh debian8 mingw64 2>&1 | tail -30` (or the relevant matrix entry available on this host).
Expected: installs `msys-cross-filesystem` + the gcc package via the from-source pacman and compiles the test programs. If the docker image/network isn't available, note it as skipped — Steps 1-3 are the load-bearing verification.

- [ ] **Step 5: Commit the plan completion marker**

```bash
git add docs/superpowers/plans/2026-06-01-pacman-from-source.md
git commit -m "docs: pacman-from-source implementation plan"
```

---

## Self-Review Notes

- **Spec coverage:** inherit_aur (Task 1) ↔ spec "inherit_aur helper"; CC/LDFLAGS re-export (Task 5 Step 1) ↔ spec "Override the toolchain via re-export"; 3 source patches (Tasks 2-4) ↔ spec patches list; package() extract-only (Task 5) ↔ spec package(); SYSHOOKDIR→msys-cross-hooks (Task 4) ↔ decision; check() rework (Task 5) ↔ spec check(); delete patch-pacman-nonroot.sh (Task 5 Step 2) ↔ spec "Deleted"; build+verify (Task 6) ↔ spec Verification.
- **openssl CARCH:** on x86_64 the AUR already selects `linux-x86_64`, so no sed of the openssl target table is needed on our arch (spec Risk #3 noted it; here it's a no-op). No task required.
- **Patch line numbers** are context hints; makepkg `patch -Np1` applies by context, tolerant of upstream drift. All three target strings were verified at commit 54d9411.
