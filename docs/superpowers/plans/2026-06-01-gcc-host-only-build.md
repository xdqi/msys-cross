# GCC Host-Only Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop compiling GCC target runtime libraries (the ~13459 `xgcc` calls that dominate the build); build only the host compiler and bundle version-matched target libs extracted from upstream MSYS2 gcc packages.

**Architecture:** Switch cross-gcc to the standard runtime-lib layout (`--disable-version-specific-runtime-libs`, matching native `mingw-w64-gcc`), build with `make all-gcc` + a granular host-only install, then in the PKGBUILD extract+relocate the gcc-internal target bits (libgcc/libstdc++/libgfortran/crt/C++ headers + runtime DLLs) from the upstream `mingw-w64-<arch>-gcc`(+`-gcc-fortran`) / msys-repo `gcc` packages into our own package. Users depend only on our package + the normal sysroot packages — never on the upstream gcc package.

**Tech Stack:** Arch Linux container, makepkg/PKGBUILD (bash), zig cc, GCC 16.1.0 (mingw) / 15.2.0 (cygwin), bsdtar, wine (verification).

**Verification model:** This is a build-system change, not unit-testable code. The "test" for each toolchain is: compile C/C++/Fortran sources with the produced cross-compiler and run the resulting PE under wine, checking exit codes. All builds run in a local `archlinux/archlinux:base-devel` docker container (matching CI), NOT against real CI.

**Gate:** Task 1 (mingw64-only PoC) must pass its capability checks before Tasks 3–4 generalize. If Task 1's search-path alignment fails, switch to route Y (Task 2 fallback) before continuing.

---

## File Structure

- `pkgs/msys-cross-gcc/PKGBUILD` — the 3 mingw targets (mingw64/mingw32/ucrt64). Rewrites upstream `_build`; has `--enable-version-specific-runtime-libs` + `make all` to change; `_package_one` install to make granular; per-target upstream-lib extraction to add.
- `pkgs/msys-cross-cygwin-gcc/PKGBUILD` — cygwin target. Rewrites `_msys2_build` (native gcc, already standard layout); `make` → host-only; extract from msys-repo `gcc` 15.2.0.
- `scripts/extract-target-libs.sh` (new) — shared helper: given an upstream `.pkg.tar.zst` and a destination, extract the gcc-internal target bits and relocate to standard-layout paths. Used by both PKGBUILDs.
- `docs/superpowers/specs/2026-06-01-gcc-host-only-build-design.md` — the approved design (reference).

---

## Task 1: mingw64 PoC — host-only build + upstream-lib repackage (THE GATE)

**Files:**
- Modify: `pkgs/msys-cross-gcc/PKGBUILD` (the `eval "$(declare -f _build | sed …)"` block near the top; `_package_one` at line ~101)
- Create: `scripts/extract-target-libs.sh`

This task proves the whole approach on one target before generalizing. Work in a local container so the host stays clean.

- [ ] **Step 1: Start a build container with the repo mounted**

```bash
cd ~/msys2-cross
docker run --rm -it -v "$PWD:/src" -w /src archlinux/archlinux:base-devel bash
# inside the container, from here on:
pacman -Sy --noconfirm --needed git nodejs curl
```

- [ ] **Step 2: Baseline — capture where the CURRENT compiler searches for target libs**

This is the reference for "search-path alignment". Using the already-installed toolchain (or after one normal build), record:

Run: `x86_64-w64-mingw32-gcc -print-search-dirs | tr ':' '\n' | grep -i mingw`
Expected: paths under `lib/gcc/x86_64-w64-mingw32/16.1.0/` (version-specific layout) — note them.

- [ ] **Step 3: Disable version-specific layout + custom pkgversion/bugurl + all-gcc in the mingw PKGBUILD**

In `pkgs/msys-cross-gcc/PKGBUILD`, add these `-e` rules to the existing `eval "$(declare -f _build | sed … )"` block (keep all existing rules):

```bash
    -e 's|--enable-version-specific-runtime-libs|--disable-version-specific-runtime-libs --with-pkgversion="msys2-cross ${pkgver}-${pkgrel}" --with-bugurl="https://github.com/xdqi/msys-cross/issues"|g' \
```

and change the existing make rule from building everything to host-only — replace:

```bash
    -e 's|\bmake all\b|make -j"$(nproc)"|g')"
```

with:

```bash
    -e 's|\bmake all\b|make -j"$(nproc)" all-gcc|g')"
```

- [ ] **Step 4: Switch `_package_one` to a granular host-only install**

In `pkgs/msys-cross-gcc/PKGBUILD`, replace the install line (currently `make -j1 DESTDIR="${pkgdir}" install` at ~line 101) with the host-only targets (modeled on native `mingw-w64-gcc`):

```bash
    make -C gcc -j1 DESTDIR="${pkgdir}" \
        install-driver install-cpp install-gcc install-gcc-ar \
        install-headers install-plugin install-lto-wrapper c++.install-common
    # cc1/cc1plus/collect2/gcov are installed by the above on cross gcc; if any
    # are missing, install explicitly from the build dir:
    for b in cc1 cc1plus collect2 lto1 lto-wrapper; do
        [ -f "gcc/$b" ] && install -Dm755 "gcc/$b" "${pkgdir}${_stage_prefix}/libexec/gcc/${target}/${pkgver}/$b" || true
    done
```

- [ ] **Step 5: Write the upstream-lib extraction helper**

Create `scripts/extract-target-libs.sh`:

```bash
#!/bin/bash
# Extract the gcc-internal target runtime libs from an upstream MSYS2 gcc package
# and relocate them into a cross-gcc install (standard layout). The host compiler
# built with --disable-version-specific-runtime-libs searches the standard paths,
# so the upstream bits drop straight in.
#
# Usage: extract-target-libs.sh <upstream-pkg.tar.zst> <target-triple> <ver> <pkgdir> <stage_prefix> [<fortran-pkg.tar.zst>]
set -euo pipefail
pkg="$1"; target="$2"; ver="$3"; pkgdir="$4"; sp="$5"; fpkg="${6:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bsdtar -xf "$pkg" -C "$tmp"
[ -n "$fpkg" ] && bsdtar -xf "$fpkg" -C "$tmp"

# Upstream mingw layout: <prefix>/{include/c++/<ver>, lib/, lib/gcc/<target>/<ver>}
# where <prefix> is mingw64 / mingw32 / ucrt64 / usr (cygwin). Detect it.
up="$(cd "$tmp" && ls -d mingw64 mingw32 ucrt64 usr 2>/dev/null | head -1)"
src="$tmp/$up"

# gcc-internal dir (libgcc.a, libgcc_eh.a, crt*.o, libgcov.a, plugin)
dst_gcc="$pkgdir$sp/lib/gcc/$target/$ver"
mkdir -p "$dst_gcc"
cp -a "$src/lib/gcc/$target/$ver/." "$dst_gcc/"

# Top-level target libs (libstdc++.a/.dll.a, libsupc++.a, libgfortran.a, libgomp.a,
# libquadmath.a, libatomic*, libgcc_s.a) → standard <prefix>/lib
dst_lib="$pkgdir$sp/$target/lib"   # cross standard sysroot lib for the target
mkdir -p "$dst_lib"
cp -a "$src/lib/." "$dst_lib/" 2>/dev/null || true

# C++ headers → <prefix>/include/c++/<ver>  (standard layout)
if [ -d "$src/include/c++" ]; then
    mkdir -p "$pkgdir$sp/$target/include/c++"
    cp -a "$src/include/c++/." "$pkgdir$sp/$target/include/c++/"
fi

# Runtime DLLs → <prefix>/bin so they're shipped with the toolchain.
mkdir -p "$pkgdir$sp/$target/bin"
find "$src" -name "lib*.dll" -exec cp -a {} "$pkgdir$sp/$target/bin/" \; 2>/dev/null || true

echo "extracted target libs for $target from $(basename "$pkg")"
```

NOTE: the exact destination subpaths (`$target/lib` vs `$target/<ver>/lib`, headers dir) are what Task 1 Step 9 VERIFIES against `-print-search-dirs`. Adjust this helper if Step 9 shows a mismatch — that adjustment IS the PoC's core finding.

```bash
chmod +x scripts/extract-target-libs.sh
git add scripts/extract-target-libs.sh
```

- [ ] **Step 6: Wire the extraction into the mingw PKGBUILD's package step (mingw64 only for now)**

In `pkgs/msys-cross-gcc/PKGBUILD`, add to `source=()` (sha256 pinned — compute in Step 7) the two upstream packages for x86_64, and in `package_msys-cross-mingw64-gcc()` after `_package_one "x86_64-w64-mingw32"` call:

```bash
    bash "$_startdir/../../scripts/extract-target-libs.sh" \
        "$srcdir/mingw-w64-x86_64-gcc-16.1.0-5-any.pkg.tar.zst" \
        "x86_64-w64-mingw32" "$pkgver" "$pkgdir" "$_stage_prefix" \
        "$srcdir/mingw-w64-x86_64-gcc-fortran-16.1.0-1-any.pkg.tar.zst"
```

Also DROP the now-unnecessary user-facing dep on the upstream gcc package (there is none currently — keep the existing sysroot deps: headers/crt/winpthreads/gcc-libs/zlib/windows-default-manifest unchanged).

- [ ] **Step 7: Pin the upstream package sha256s**

```bash
cd /tmp
curl -sLO https://repo.msys2.org/mingw/mingw64/mingw-w64-x86_64-gcc-16.1.0-5-any.pkg.tar.zst
curl -sLO https://repo.msys2.org/mingw/mingw64/mingw-w64-x86_64-gcc-fortran-16.1.0-1-any.pkg.tar.zst
sha256sum mingw-w64-x86_64-gcc-*.pkg.tar.zst
```
Put these URLs + sha256 into `source=()`/`sha256sums=()` of `pkgs/msys-cross-gcc/PKGBUILD`.

- [ ] **Step 8: Build the gcc package only, in the container**

One-time prep (zig + sysroots + static deps) so the single-package builder has its inputs — run the full orchestrator once and let it reach the gcc step, OR run the prep steps directly:
```bash
# one-time prep (idempotent; skips already-built):
bash scripts/prepare-zig.sh && bash scripts/prepare-build-sysroot.sh
# build_deps as an unprivileged user (matches build.sh):
useradd -m builduser 2>/dev/null; chown -R builduser /src
runuser -u builduser -- env PATH="$PATH" bash scripts/build_deps.sh
```
Then build just the gcc package (it builds all 3 mingw targets; that's fine for the PoC — we only verify mingw64):
```bash
runuser -u builduser -- env PATH="$PATH" bash scripts/build_packages.sh msys-cross-gcc -fCd --skippgpcheck 2>&1 | tee /tmp/build.log
```
Expected: build completes WITHOUT the target-lib compile phase.

Run: `grep -c 'all-target' /tmp/build.log`
Expected: 0 (no target-lib build).

Run: `grep -c 'xgcc' /tmp/build.log`
Expected: dramatically lower than the ~13459 baseline (ideally ~0).

- [ ] **Step 9: VERIFY search-path alignment (the crux)**

Install the produced package into a test prefix and check the compiler finds the repackaged libs:
```bash
x86_64-w64-mingw32-gcc -print-search-dirs | tr ':' '\n' | grep -i mingw
ls "$(x86_64-w64-mingw32-gcc -print-file-name=libstdc++.a)"
ls "$(x86_64-w64-mingw32-gcc -print-file-name=crtbegin.o)"
ls "$(x86_64-w64-mingw32-gcc -print-file-name=libgcc.a)"
```
Expected: each `-print-file-name` resolves to a REAL file inside the install (not just echoing the name = not found). If any echoes the bare name, the helper's destination paths (Step 5) are wrong — adjust and rebuild. **This loop is the PoC.**

- [ ] **Step 10: VERIFY capability — compile + link + run C/C++/Fortran under wine**

```bash
cd /tmp && printf 'int main(void){return 42;}\n' > h.c
printf '#include <iostream>\nint main(){std::cout<<"ok\\n";return 0;}\n' > h.cc
printf 'program t\nend program\n' > h.f90
x86_64-w64-mingw32-gcc      -o hc.exe   h.c   && wine hc.exe;   echo "C   exit=$?"
x86_64-w64-mingw32-g++      -o hcc.exe  h.cc  && WINEPATH="$(dirname "$(x86_64-w64-mingw32-gcc -print-file-name=libstdc++-6.dll)")" wine hcc.exe; echo "C++ exit=$?"
x86_64-w64-mingw32-gfortran -o hf.exe   h.f90 && wine hf.exe;   echo "Fortran exit=$?"
```
Expected: C exit 42; C++ prints `ok` exit 0; Fortran exit 0. C++ static fallback (`-static`) must also work. If all green, the PoC PASSES.

- [ ] **Step 11: Commit the PoC (mingw64 path) if green**

```bash
git add pkgs/msys-cross-gcc/PKGBUILD scripts/extract-target-libs.sh
git commit -m "gcc(mingw64): PoC host-only build + repackage upstream target libs

make all-gcc + granular host install + --disable-version-specific-runtime-libs;
extract libgcc/libstdc++/libgfortran/crt/C++ headers + DLLs from upstream
mingw-w64-x86_64-gcc(+fortran) into our package. Verified C/C++/Fortran compile,
link, and run under wine."
```

---

## Task 2: Route-Y fallback (ONLY if Task 1 Step 9 search-path alignment fails)

**Skip this task if Task 1 passed.** If `--disable-version-specific-runtime-libs` does not make the cross compiler find the standard-layout libs, keep the upstream `--enable-version-specific-runtime-libs` and relocate the extracted bits into `lib/gcc/<target>/<ver>/` instead.

- [ ] **Step 1: Revert the version-specific sed change** (keep `--enable-version-specific-runtime-libs`); keep the `all-gcc` + granular-install + pkgversion/bugurl changes.

- [ ] **Step 2: Change the helper's destinations** in `scripts/extract-target-libs.sh` so C++ headers go to `$pkgdir$sp/lib/gcc/$target/$ver/include/c++` and the `.a` libs to `$pkgdir$sp/lib/gcc/$target/$ver/` (the version-specific paths), matching the layout the unchanged-configure compiler searches.

- [ ] **Step 3: Re-run Task 1 Steps 8–11.** Proceed to Task 3 once green.

---

## Task 3: Generalize to mingw32 + ucrt64

**Files:** Modify `pkgs/msys-cross-gcc/PKGBUILD`

- [ ] **Step 1: Add the upstream packages for i686 and ucrt to `source=()`/`sha256sums=()`**

```bash
cd /tmp
for p in mingw-w64-i686-gcc-16.1.0-5 mingw-w64-i686-gcc-fortran-16.1.0-1; do curl -sLO "https://repo.msys2.org/mingw/mingw32/$p-any.pkg.tar.zst"; done
for p in mingw-w64-ucrt-x86_64-gcc-16.1.0-5 mingw-w64-ucrt-x86_64-gcc-fortran-16.1.0-1; do curl -sLO "https://repo.msys2.org/mingw/ucrt64/$p-any.pkg.tar.zst"; done
sha256sum mingw-w64-i686-gcc-*.pkg.tar.zst mingw-w64-ucrt-x86_64-gcc-*.pkg.tar.zst
```
Add the four URLs + sha256 to the PKGBUILD.

- [ ] **Step 2: Call the extraction helper in `package_msys-cross-mingw32-gcc()` and `package_msys-cross-ucrt64-gcc()`**

After each `_package_one` call, mirror the mingw64 call from Task 1 Step 6 with the matching triple/pkg names:
```bash
# mingw32:
bash "$_startdir/../../scripts/extract-target-libs.sh" \
    "$srcdir/mingw-w64-i686-gcc-16.1.0-5-any.pkg.tar.zst" \
    "i686-w64-mingw32" "$pkgver" "$pkgdir" "$_stage_prefix" \
    "$srcdir/mingw-w64-i686-gcc-fortran-16.1.0-1-any.pkg.tar.zst"
# ucrt64:
bash "$_startdir/../../scripts/extract-target-libs.sh" \
    "$srcdir/mingw-w64-ucrt-x86_64-gcc-16.1.0-5-any.pkg.tar.zst" \
    "x86_64-w64-mingw32ucrt" "$pkgver" "$pkgdir" "$_stage_prefix" \
    "$srcdir/mingw-w64-ucrt-x86_64-gcc-fortran-16.1.0-1-any.pkg.tar.zst"
```

- [ ] **Step 3: Build all three mingw targets in the container; verify each with the Task 1 Step 10 capability check** (substituting `i686-w64-mingw32-` and `x86_64-w64-mingw32ucrt-`).

Expected: C exit 42, C++ `ok` exit 0, Fortran exit 0 for all three.

- [ ] **Step 4: Commit**

```bash
git add pkgs/msys-cross-gcc/PKGBUILD
git commit -m "gcc(mingw32/ucrt64): host-only build + repackage upstream target libs"
```

---

## Task 4: Generalize to cygwin

**Files:** Modify `pkgs/msys-cross-cygwin-gcc/PKGBUILD`

cygwin-gcc inherits native gcc's `build()` (already standard layout — no version-specific to disable), so only the `make`→host-only, granular install, pkgversion/bugurl, and extraction need adding.

- [ ] **Step 1: Make the cygwin build host-only**

In the `eval "$(declare -f _msys2_build | sed …)"` block, change the make rule from `-e 's|\bmake$|make -j"$(nproc)"|'` to `-e 's|\bmake$|make -j"$(nproc)" all-gcc|'`, and inject pkgversion/bugurl onto the configure line (append to the existing big `--enable-libstdcxx-filesystem-ts;` replacement): add `--with-pkgversion=\"msys2-cross ${pkgver}-${pkgrel}\" --with-bugurl=\"https://github.com/xdqi/msys-cross/issues\"`.

- [ ] **Step 2: Granular host-only install** — replace `make -j1 DESTDIR="${pkgdir}" install` (line ~134) with the same `make -C gcc … install-driver install-cpp install-gcc …` block from Task 1 Step 4 (target = `x86_64-pc-cygwin`).

- [ ] **Step 3: Pin + extract the msys-repo gcc 15.2.0**

```bash
cd /tmp
curl -sLO https://repo.msys2.org/msys/x86_64/gcc-15.2.0-1-x86_64.pkg.tar.zst
sha256sum gcc-15.2.0-1-x86_64.pkg.tar.zst
```
Add URL+sha256 to `source=()`. In `package_msys-cross-cygwin-gcc()` after `_package_one "x86_64-pc-cygwin"`, call:
```bash
bash "$_startdir/../../scripts/extract-target-libs.sh" \
    "$srcdir/gcc-15.2.0-1-x86_64.pkg.tar.zst" \
    "x86_64-pc-cygwin" "$pkgver" "$pkgdir" "$_stage_prefix"
```
(The msys gcc package uses `usr/` prefix — the helper's `up` detection already includes `usr`.)

- [ ] **Step 4: Build cygwin-gcc; verify C + C++ compile to PE** (cygwin has no Fortran). Run under wine if a cygwin runtime is available; otherwise confirm `file *.exe` shows PE32+ and `-print-file-name` resolves libstdc++.a/crtbegin.o to real files.

- [ ] **Step 5: Commit**

```bash
git add pkgs/msys-cross-cygwin-gcc/PKGBUILD
git commit -m "cygwin-gcc: host-only build + repackage upstream (msys gcc 15.2.0) target libs"
```

---

## Task 5: Full build + CI source-cache key + final verification

**Files:** `.github/workflows/build.yml` (cache key includes the new upstream pkgs), `scripts/build.sh` (none expected)

- [ ] **Step 1: Run the complete `bash scripts/build.sh` in the container** and confirm all four toolchains build, the repo DB + bootstrap assemble, and the build is substantially faster than the ~1h26m baseline (grep the log: `grep -c xgcc` should be near-zero).

- [ ] **Step 2: Confirm the upstream gcc tarballs are covered by the pkg-source cache** — they are downloaded into `SRCDEST` (`build/sources`) by makepkg, which the existing `pkg-src-*` cache already captures (keyed by submodule SHA + `pkgs/**`; the PKGBUILD change bumps the key). No workflow change needed unless the tarballs land elsewhere; if so, add their dir to the `Cache pkg source tarballs` path.

- [ ] **Step 3: Capability matrix** — for all four targets, compile+link+run (wine) C and C++ (and Fortran for the 3 mingw), confirming exit codes. Record results.

- [ ] **Step 4: Verify `gcc --version` shows the custom pkgversion**

Run: `x86_64-w64-mingw32-gcc --version | head -1`
Expected: contains `msys2-cross 16.1.0-...`.

- [ ] **Step 5: Commit any workflow change + push**

```bash
git add .github/workflows/build.yml 2>/dev/null || true
git commit -m "ci: cover upstream gcc tarballs in pkg-source cache" 2>/dev/null || true
# push only when the user approves a CI run
```

---

## Notes for the implementer

- **Do not push** until the user approves — a push triggers a ~real CI build/release.
- The `_stage_prefix` variable is set inside `build()`/`_package_one` in the existing PKGBUILDs; the extraction helper receives it so destinations match the staged install.
- Keep the existing sysroot `depends=()` (headers/crt/winpthreads/gcc-libs/zlib/windows-default-manifest) — these are the target runtime the built `.exe` needs and are NOT what we repackage.
- The debug-split (`options=('strip' 'debug')`) and `pkgbase` overrides from earlier work stay; with far fewer objects, the `*-debug` package will shrink — expected.
