# Design: build cross-gcc host-only, source target libs from upstream

## Context

The msys2-cross GCC build is dominated by compiling the **target runtime
libraries** (libgcc, libstdc++, libgfortran, libgomp, libquadmath, crt objects)
with the freshly-built `xgcc`. A CI build measured **13459 `xgcc` invocations**
for these target libs versus ~1719 host-side compiles. sccache only sees the
host side (compiles routed through `zigcc`/`$CC`); `xgcc` bypasses it entirely,
so the cache barely dents total build time (~1h26m, mostly target libs).

Those target libraries are **already published, version-matched, by MSYS2**:

| Target | Upstream package (repo) | Version | Matches our |
|---|---|---|---|
| x86_64-w64-mingw32 | `mingw-w64-x86_64-gcc` (+`-gcc-fortran`) | 16.1.0 | 16.1.0 ✓ |
| i686-w64-mingw32 | `mingw-w64-i686-gcc` (+`-gcc-fortran`) | 16.1.0 | 16.1.0 ✓ |
| x86_64-w64-mingw32ucrt | `mingw-w64-ucrt-x86_64-gcc` (+`-gcc-fortran`) | 16.1.0 | 16.1.0 ✓ |
| x86_64-pc-cygwin | `gcc` (msys repo) | 15.2.0 | 15.2.0 ✓ |

So building them ourselves is pure waste. **Goal: build only the host compiler
and obtain the target runtime libs from upstream — without reducing toolchain
capability** (C/C++/Fortran for all four targets must still compile and link).

## Key findings (verified)

- `--enable-version-specific-runtime-libs` is set by **upstream
  `mingw-w64-cross-gcc`** (not us); it puts target libs/headers under
  `lib/gcc/<target>/<ver>/`.
- Upstream **native** `mingw-w64-gcc` does **not** set it → standard layout
  (`include/c++/<ver>/`, `lib/libstdc++.a`). This is the layout the published
  gcc packages use.
- GCC supports host/target-separated install: `make -C gcc install-driver
  install-cpp install-gcc install-headers install-lto-wrapper` installs only the
  compiler proper (native `mingw-w64-gcc` does exactly this). `make all-gcc`
  builds only the host compiler, skipping `all-target-*`.
- The MSYS2 `gcc` (msys repo) `gcc-15.2.0-1` has target triple
  `x86_64-pc-cygwin` (identical to ours) — so cygwin has a clean upstream source.

## Approach (route X: match the standard layout)

Make our cross-gcc use the **standard runtime-lib layout** (same as native
`mingw-w64-gcc`) so the host compiler and the upstream-provided target libs share
one layout and need no relocation.

### 1. configure changes (in the `_build` sed-override of pkgs/msys-cross-gcc/PKGBUILD)

The build already rewrites the inherited `_build()` via
`eval "$(declare -f _build | sed ...)"`. Add:

- `--enable-version-specific-runtime-libs` → `--disable-version-specific-runtime-libs`
  (standard layout).
- Inject project-specific `--with-pkgversion="msys2-cross ..."` and
  `--with-bugurl="<project url>"` (upstream cross-gcc sets neither; native sets
  both to MSYS2's — we set our own).
- `make all` → `make all-gcc` (host compiler only; skips the 13459 xgcc target-lib
  compiles). The existing `s|make all|make -j"$(nproc)"|` rule becomes
  `make -j"$(nproc)" all-gcc`.

Concrete values: `--with-pkgversion="msys2-cross ${pkgver}-${pkgrel}"` and
`--with-bugurl="https://github.com/xdqi/msys-cross/issues"`. These surface in
`gcc --version` so a user can tell it's the msys2-cross build.

**Thread model (decided during PoC):** also flip `--enable-threads=win32` →
`--enable-threads=posix`. The bundled upstream libstdc++ is posix-threads; our
compiler must match or static C++ fails to link (`pthread_mutex_*`). Threads is
the only ABI-relevant divergence from the native gcc that built the bundled libs
(exception model, string ABI, etc. already match). The sed targets the literal
`--enable-threads=${_threads}` (declare -f does not expand `${_threads}`).

### 2. install changes — split into `-gcc` (C/C++) and `-gcc-fortran`

Replace `make … install` with host-only granular targets (modeled on native
`mingw-w64-gcc`), and **split fortran into its own subpackage** (upstream splits
`gcc` / `gcc-fortran` / `gcc-libgfortran` for the same reason — Fortran is a large,
rarely-used add-on). Our packages mirror the gcc / gcc-fortran boundary (no
separate libgfortran-runtime package; the runtime DLL stays a sysroot concern).

- **`msys-cross-<sub>-gcc`** (C/C++): `_package_one` installs only the C/C++
  host bits + repackages the C/C++ target libs. Use the **C/C++-only** install
  targets — NOT the broad `install-common` (which pulls fortran too):
  `make -C gcc … c++.install-common install-driver install-cpp install-gcc-ar
  install-headers install-plugin install-lto-wrapper`, plus explicit backend
  binaries `cc1 cc1plus collect2 lto1 lto-wrapper` and `liblto_plugin.so`.
- **`msys-cross-<sub>-gcc-fortran`** (new): `_package_one_fortran` installs the
  fortran driver + backend + libgfortran: `make -C gcc … fortran.install-common`,
  the `f951` backend binary, and the libgfortran bits extracted from the upstream
  `mingw-w64-<arch>-gcc-fortran` package. `depends` on the matching `-gcc`
  package (so installing fortran pulls the C/C++ compiler).

This both fixes a PoC-discovered bug (the broad `install-common` did not actually
deliver `f951`/the gfortran driver — Fortran was incomplete) and lets users who
don't need Fortran install the smaller `-gcc` package alone.

No `make -C <target>/lib*… install` — target libs are not built; they are
repackaged from upstream (next section).

### 3. target gcc-internal libs are repackaged at build time (no upstream-gcc dep for users)

The end user must NOT have to install the upstream MSYS2 **gcc** package. Instead,
at PKGBUILD time we download the upstream gcc package, extract the gcc-internal
target bits that `make all-gcc` no longer produces, and bundle them into our own
`msys-cross-*-gcc` package (relocated to the standard layout our host compiler
searches). The user installs only our package (+ the normal sysroot packages).

Split of responsibility:

- **Repackaged into our `-gcc` package** (C/C++ gcc-internal, version-locked):
  `libgcc.a`, `libgcc_eh.a`, `libgcov.a`, `crtbegin.o`, `crtend.o`,
  `crtfastmath.o`, `libstdc++.a`/`.dll.a`, `libsupc++.a`, `libstdc++exp.a`/`fs.a`,
  the C++ headers (`include/c++/<ver>/`), `libgomp.a`, `libquadmath.a`,
  `libatomic.a`. Extract from `mingw-w64-<arch>-gcc` (mingw repo, 16.1.0); cygwin
  from the msys repo `gcc` 15.2.0.
- **Repackaged into our `-gcc-fortran` package**: `libgfortran.a`/`.dll.a`/`.spec`
  extracted from `mingw-w64-<arch>-gcc-fortran` (16.1.0). (cygwin has no Fortran
  → no cygwin-gcc-fortran package.)
- NOTE: the runtime DLLs (`libstdc++-6.dll`, `libgcc_s_seh-1.dll`,
  `libgfortran-5.dll`) are NOT repackaged — they live in the upstream `gcc-libs`
  package and reach the target as a sysroot dep (see below). The extraction
  helper must select only link-time `.a`/headers/`.o`/`.spec`, not sweep DLLs
  (in particular not the host `liblto_plugin.dll`).
- **Kept as `depends` (genuine target sysroot, unchanged)**:
  `mingw-w64-<arch>-{headers,crt,winpthreads,gcc-libs,zlib,windows-default-manifest}`.
  `gcc-libs` here is the target system's runtime DLLs that the built `.exe`
  loads — that belongs to the target's package set, not bundled into a
  cross-compiler. The toolchain already requires these regardless.

Extraction happens in `prepare()`/`package()` via `bsdtar -x` of the upstream
`.pkg.tar.zst` (sha256-pinned, fetched into `SRCDEST`), then relocating the bits
into the package's standard-layout paths. No new runtime dependency on the
upstream gcc package.

### 4. scope unchanged

binutils, pacman, clang, the mirror, CI — all unchanged. Only the four gcc
PKGBUILDs (`msys-cross-gcc` for the 3 mingw, `msys-cross-cygwin-gcc`) change.

## Risks / must-verify (local container PoC)

This is a real build-architecture change; a **mingw64-only PoC, run in a local
`archlinux/archlinux:base-devel` docker container** (not CI), gates it before
touching all four targets:

1. **`make all-gcc` completeness** — does the gcc subdir build/install cleanly
   without ever building target libgcc? (Expected yes; configure already ran.)
2. **Search-path alignment** — with `--disable-version-specific-runtime-libs`,
   does the host compiler's `-print-search-dirs` find the repackaged
   `libgcc.a`/`libstdc++.a`/`crtbegin.o`/C++ headers at the standard-layout paths
   we relocate them to? This is the crux of route X and decides X vs the Y
   fallback.
3. **Repackaging fidelity** — the extracted+relocated upstream bits must land at
   exactly the paths the host compiler searches, and be ABI-compatible with our
   `all-gcc`-built driver (same version + configure, so expected compatible).
4. **End-to-end capability** — compile + link C, C++ (`<iostream>`), and Fortran
   to PE, run under wine, exit codes correct (as already done for the current
   toolchain). C++ must find headers + libstdc++; static link must find crt+libgcc.
5. **Granular install target names** — confirm `install-driver/install-cpp/…`
   exist for our GCC 16 + cross configuration.

PoC steps (local docker): rebuild `msys-cross-mingw64-gcc` with the route-X
changes (`all-gcc` + granular host install + extract/relocate upstream
`mingw-w64-x86_64-gcc`+`-gcc-fortran` target bits), then run the C/C++/Fortran
compile-link-wine checks. If green, generalize to all four targets; if search-path
alignment fails, fall back to route Y (keep version-specific layout, relocate
upstream libs into `lib/gcc/<target>/<ver>/`). The repackaging logic is identical
in both routes — only the destination paths differ.

## Expected payoff

Eliminating `all-target-*` removes the ~13459 xgcc compiles — the bulk of the
~1h26m build — leaving only the host compiler (already sccache-cached). Build
time should drop substantially; sccache then covers nearly all of what remains.
