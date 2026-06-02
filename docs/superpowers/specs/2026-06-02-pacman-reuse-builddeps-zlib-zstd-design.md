# pacman reuse build_deps zlib/zstd — design

Date: 2026-06-02

## Context

`msys-cross-pacman` builds pacman + 13 static deps from source (see
[2026-06-01-pacman-from-source-design.md]). Two of those — **zlib** and **zstd** —
are also built by the repo's `scripts/build_deps.sh` (for gcc/binutils) into
`deps/install`. In the full `scripts/build.sh` flow, `build_deps.sh` runs *before*
`msys-cross-pacman`, so `deps/install/lib/{libz,libzstd}.a` already exist when
pacman builds — yet pacman recompiles its own copies anyway. The versions happen to
match exactly (zlib 1.3.2, zstd 1.5.7).

Goal: make pacman **reuse** build_deps' prebuilt zlib/zstd, dropping 2 of its 13
dep compiles. Decisions settled with the user:
- **Hard dependency** on `deps/install` (no fallback to self-build): pacman asserts
  the libs exist and exits with a clear message if not. Standalone builds of
  `msys-cross-pacman` must run `build_deps.sh` first.
- **No version-consistency check** between build_deps and the AUR `_zlibver`/`_zstdver`.
- The missing `libzstd.pc` is added in **build_deps.sh** (zlib already ships `zlib.pc`).
- Injection: **copy** build_deps' zlib/zstd artifacts into the AUR build's
  `temp/usr`, and **sed-neutralize** the AUR's two build blocks. Consumers are
  unchanged.

## How consumers find zlib/zstd (unchanged)

All consumers resolve via the AUR build's `$srcdir/temp/usr`:
- **curl**: explicit `--with-zlib-include/lib=temp/usr` and `--with-zstd-include/lib=temp/usr`.
- **libarchive, pacman (meson)**: `PKG_CONFIG_PATH=$srcdir/temp/usr/lib/pkgconfig`
  → need `zlib.pc` and `libzstd.pc` there.

So the reuse strategy populates `temp/usr` (lib + include + pkgconfig) from
`deps/install`; no consumer edits, and no `deps/install` path added to any global
`-I`/`-L` (avoids header-leak coupling).

## Changes

### 1. `scripts/build_deps.sh` — zstd installs its `.pc`

Today the zstd step manually `cp`s `libzstd.a` + 3 headers, omitting `libzstd.pc`.
Change it to use zstd's own install targets (as the AUR build does), so
`deps/install/lib/pkgconfig/libzstd.pc` exists:

```sh
echo "=== zstd ==="
cd "$WORK_DEPS/zstd-${ZSTD_VER}/lib"
CFLAGS="-O2 -fPIC" make -j"$JOBS" libzstd.a
make PREFIX="$PREFIX" install-pc install-static install-includes
```

zlib already installs `zlib.pc` via `make install` — unchanged. The existing
`.so→.a` symlink loop (for zig's no_fallback linker) stays. This change is inert
for gcc/binutils (they don't read `libzstd.pc`); it only adds a file.

### 2. `pkgs/msys-cross-pacman/PKGBUILD` — reuse instead of rebuild

**(a) Hard-require build_deps' zlib/zstd.** After `inherit_aur`, assert the static
libs exist; fail loudly otherwise:

```bash
for _lib in libz.a libzstd.a; do
    [ -f "$_deps/lib/$_lib" ] || {
        echo "ERROR: $_deps/lib/$_lib missing — run scripts/build_deps.sh first" >&2
        return 1   # in a PKGBUILD top-level this aborts sourcing; mirror in build() too
    }
done
```
(Place the same guard at the start of `build()` so a `--noextract`/resume path also
catches it — top-level assertions run at source time, but build() is the reliable
gate.)

**(b) Populate `temp/usr` from `deps/install`, then run the AUR build.** Our
`build()` seeds `temp/usr` before `_aur_build`:

```bash
build() {
    local t="${srcdir}/temp/usr"
    mkdir -p "$t/lib/pkgconfig" "$t/include"
    cp -a "$_deps/lib/libz.a"    "$t/lib/"
    cp -a "$_deps/lib/libzstd.a" "$t/lib/"
    cp -a "$_deps/include/zlib.h" "$_deps/include/zconf.h" "$t/include/"
    cp -a "$_deps/include/zstd.h" "$_deps/include/zdict.h" "$_deps/include/zstd_errors.h" "$t/include/"
    cp -a "$_deps/lib/pkgconfig/zlib.pc"    "$t/lib/pkgconfig/"
    cp -a "$_deps/lib/pkgconfig/libzstd.pc" "$t/lib/pkgconfig/"
    _aur_build
}
```
The AUR `build()` runs `mkdir -p` / `install` into `temp/usr` for its other deps,
so pre-creating it is safe.

**(c) Sed-neutralize the AUR zlib/zstd build blocks.** In `inherit_aur`'s save of
`build` (or a follow-on sed in the PKGBUILD), replace the two blocks so they don't
recompile. The blocks are delimited by their `# zstd` / `# zlib` comments and the
next `# <dep>` comment. Concretely, transform `_aur_build` to no-op:
- the zstd block: `cd "${srcdir}"/zstd-*/lib; make libzstd.a; make ... install-*`
- the zlib block: `cd "${srcdir}/"zlib-*; ./configure ...; make libz.a; make install`

Implementation: a `sed` over `declare -f build` that deletes the line ranges
between `# zstd`→`# brotli` and `# zlib`→`# openssl` (keeping the `# brotli`/`# openssl`
markers), or replaces each block's commands with `:`. The PKGBUILD already does a
similar targeted sed for the libarchive CFLAGS line, so this is the same mechanism.
Source-list zlib/zstd downloads are LEFT in place (harmless; removing them risks
desyncing the AUR source/sums arrays — YAGNI).

## Data flow

```
scripts/build_deps.sh  →  deps/install/{lib/libz.a,libzstd.a,
                                         lib/pkgconfig/{zlib.pc,libzstd.pc},
                                         include/{zlib.h,zstd.h,...}}
        │  (build.sh runs this BEFORE msys-cross-pacman)
        ▼
pkgs/msys-cross-pacman/PKGBUILD
   guard: assert deps/install zlib+zstd exist (else exit)
   build(): cp those into $srcdir/temp/usr/{lib,include,lib/pkgconfig}
            sed-neutralized _aur_build skips its own zlib/zstd compile
   → curl/libarchive/pacman find zlib+zstd in temp/usr as before
```

## Risks

1. **sed block-removal fragility.** The two blocks are matched by `# zstd`/`# zlib`
   comment anchors. If a future AUR bump renames/reorders them, the sed silently
   no-ops and pacman would recompile (correctness preserved, just no speedup) — or,
   worse, mis-deletes. Mitigation: anchor on the exact `cd "${srcdir}"/zstd-` and
   `cd "${srcdir}/"zlib-` lines; verify after sed that `declare -f build` no longer
   contains `make libzstd.a` / `make libz.a`, else fail loudly.
2. **Header set drift.** If build_deps' zstd `install-includes` ships a different
   header set than pacman's consumers expect, a consumer could miss a header. Low
   risk (same zstd version). Copying via `install-includes`-produced files (not a
   hardcoded list) in build_deps reduces this; the PKGBUILD copy list mirrors the
   AUR's own `install-includes` outputs (zstd.h, zdict.h, zstd_errors.h).
3. **Standalone build breakage.** Building only `msys-cross-pacman` without first
   running `build_deps.sh` now hard-fails. This is intended (per decision) — the
   container verification and any `build_packages.sh msys-cross-pacman` invocation
   must run `build_deps.sh` first.

## Verification

1. **build_deps emits libzstd.pc:** run `scripts/build_deps.sh` (or just its zstd
   step) and confirm `deps/install/lib/pkgconfig/libzstd.pc` + `zlib.pc` exist and
   `pkg-config --modversion libzstd zlib` (with `PKG_CONFIG_PATH=deps/install/lib/pkgconfig`)
   report the expected versions.
2. **pacman reuse (container, like prior task):** with `deps/install` populated,
   build `msys-cross-pacman`; confirm the build log shows the zstd/zlib AUR steps
   skipped (no `make libzstd.a`/`make libz.a` for those), the other 11 deps + pacman
   still compile, check() passes, and the artifact is unchanged (mostly-static, same
   behavioural results: non-root no-chown, *.exe skipped, hook neutralized).
3. **Hard-dependency guard:** build `msys-cross-pacman` with an empty `deps/install`
   and confirm it fails fast with the "run build_deps.sh first" message (not a
   confusing mid-build error).
4. **Full flow unaffected:** `scripts/build.sh` order (build_deps → pacman) still
   produces a working pacman and the downstream gcc/binutils builds are unchanged
   (the build_deps zstd `.pc` addition is inert for them).
