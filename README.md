# msys2-cross

A relocatable **Windows cross-compiler toolchain**, built on Linux and
distributed as a pacman repository. It provides GCC + binutils for the standard
MSYS2 targets, installable into any prefix and movable anywhere — the compilers
are built with `zig cc` against a glibc 2.11 ABI, so they run on old and new
Linux distros alike.

Windows target runtimes (headers, CRT, winpthreads, …) are pulled from the
official MSYS2 repositories rather than rebuilt, so the toolchain stays in lock
step with upstream MSYS2.

## Targets

| Target triple | Runtime | Compiler |
|---|---|---|
| `x86_64-w64-mingw32` | msvcrt | GCC 16.1.0 |
| `i686-w64-mingw32` | msvcrt | GCC 16.1.0 |
| `x86_64-w64-mingw32ucrt` | UCRT | GCC 16.1.0 |
| `x86_64-pc-cygwin` | cygwin | GCC 15.2.0 |
| `x86_64-w64-mingw32` (clang64) | UCRT | host clang/lld wrapper |
| `aarch64-w64-mingw32` (clangarm64) | UCRT | host clang/lld wrapper |

binutils 2.46.0 across all targets. Each compiler is invoked with no special
flags — `x86_64-w64-mingw32-gcc -o foo.exe foo.c`.

## Install & use

The only manual step is unpacking the bootstrap (a static, relocatable pacman
plus the repo config); everything else is pulled on demand.

```sh
# 1. Unpack the bootstrap into a prefix of your choice.
curl -L https://msys.kosaka.moe/repo/bootstrap.tar.xz | sudo tar -xJ -C /opt
export PATH="/opt/msys2-cross/bin:$PATH"

# 2. Install the toolchain(s) you want. Sysroot packages are pulled
#    automatically via dependencies.
msys-pacman -Sy
msys-pacman -S msys-cross-mingw64-gcc      # or -mingw32-/-ucrt64-/-cygwin-gcc

# 3. Compile.
x86_64-w64-mingw32-gcc -o hello.exe hello.c
```

`msys-pacman` is a thin wrapper around a static pacman pinned to this prefix
(`--root`/`--config`/`--dbpath`). The bundled pacman is patched so it does **not**
require root, so once the prefix is writable by your user, upgrades are just
`msys-pacman -Syu` — no `sudo`. (The very first install into a root-owned prefix
still needs `sudo`; afterwards `chown` the prefix to your user.)

To pin a specific snapshot instead of the rolling latest, point the
`[msys-cross]` server at an archive tag — see
[msys-mirror](msys-mirror/README.md).

## How it's distributed

Packages are **not** stored on a server. They live as **GitHub Release assets**
(GitHub provides the storage and CDN); a small front-end
([`msys-mirror/`](msys-mirror/README.md)) generates the directory listing and
302-redirects each package/db request to the matching asset. `https://msys.kosaka.moe/repo`
tracks the latest release; `/archive/<tag>/` serves an immutable snapshot.

## Repository layout

| Path | What |
|---|---|
| [`pkgs/`](pkgs/) | PKGBUILDs for each `msys-cross-*` package (gcc, binutils, cygwin-gcc, clang, pacman, filesystem, ca-certificates, pkgconfig) |
| [`scripts/`](scripts/) | Build orchestration (`build.sh`) and helpers |
| [`deps/MSYS2-packages`](deps/) | Submodule — upstream MSYS2 PKGBUILDs; the gcc/binutils versions are inherited from here |
| [`msys-mirror/`](msys-mirror/) | The GitHub-Releases-backed pacman repo front-end (Go + Dockerfile) |
| [`.github/workflows/`](.github/workflows/) | CI: full build → release publish |

The gcc/binutils PKGBUILDs don't hard-code versions; `scripts/msys-cross-common.sh`'s
`inherit_msys2` sources the upstream PKGBUILD from the submodule, then overrides
metadata and build flags. Bumping the toolchain = bumping the submodule.

## Building it yourself

The whole build is self-contained and runs in an Arch Linux container (it drives
`pacman` directly):

```sh
bash scripts/build.sh
```

This runs, in order: prepare Zig → prepare the MSYS2 build sysroots →
build the static deps (gmp/mpfr/mpc/isl/zlib/zstd) → build each package with
`makepkg` in dependency order → assemble the repo DB → build the bootstrap
tarball. Output lands in `repo/`.

Key build properties:

- **Compiler driver:** `scripts/zigcc` / `zigc++` (`zig cc`/`zig c++` targeting
  `x86_64-linux-gnu.2.11`). When `sccache` is present they route through it for a
  cached rebuild.
- **Debug symbols:** gcc/binutils ship stripped, with a separate `*-debug`
  package carrying the split symbols (only host-ELF compiler binaries are
  stripped; the Windows/Cygwin target objects are left intact).
- **pacman:** repackaged from the archlinuxcn static build and binary-patched to
  drop the root requirement (`pkgs/msys-cross-pacman/patch-pacman-nonroot.sh`),
  verified non-root in the package's `check()`.

### CI / releases

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs the build in an
`archlinux/archlinux:base-devel` container and, on push to `main`, publishes a
GitHub Release tagged `build-YYYYMMDD.N` with all packages + the repo DB +
`bootstrap.tar.xz`. Source tarballs and compiler objects (via sccache) are cached
between runs.

## Status

The published toolchains have been verified end-to-end: C and C++ for all four
GCC targets compile to valid PE/Cygwin executables that run under wine
(`x86_64`, `i686`, UCRT, Cygwin).
