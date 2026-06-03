# msys2-cross

**Compile Windows programs from Linux.** This is a ready-to-use toolchain — you
get commands like `x86_64-w64-mingw32-gcc` that turn your `.c`/`.cpp` files into
Windows `.exe` files, without needing Windows or MSYS2 installed.

Install once, then use it like any other compiler. The toolchain installs into a
single folder you can move anywhere, and it works on both old and new Linux
distros.

## Install

You need three things: download a small bootstrap, add it to your `PATH`, then
install the compiler you want. That's it.

```sh
# 1. Download and unpack the bootstrap (a self-contained package manager).
sudo mkdir -p /opt
curl -L https://msys.kosaka.moe/repo/bootstrap.tar.xz | sudo tar -xJ -C /opt

# 2. Add it to your PATH (put this in ~/.bashrc to make it permanent).
export PATH="/opt/msys2-cross/bin:$PATH"

# 3. Let your user own the install, so future updates need no sudo.
sudo chown -R "$(id -un)" /opt/msys2-cross

# 4. Install a compiler. The Windows headers/libraries it needs are
#    downloaded automatically.
msys-pacman -Sy
msys-pacman -S msys-cross-mingw64-gcc
```

Pick the compiler that matches your target:

| Install this | Gives you the command | Builds |
|---|---|---|
| `msys-cross-mingw64-gcc` | `x86_64-w64-mingw32-gcc` | 64-bit Windows |
| `msys-cross-mingw32-gcc` | `i686-w64-mingw32-gcc` | 32-bit Windows |
| `msys-cross-ucrt64-gcc` | `x86_64-w64-mingw32ucrt-gcc` | 64-bit Windows (UCRT) |
| `msys-cross-cygwin-gcc` | `x86_64-pc-cygwin-gcc` | Cygwin |

## Use

Just call the compiler — no special flags needed. Use `-gcc` for C and `-g++`
for C++:

```sh
echo 'int main(){ return 0; }' > hello.c
x86_64-w64-mingw32-gcc -o hello.exe hello.c   # produces a Windows .exe
```

Copy `hello.exe` to a Windows machine (or run it with `wine hello.exe`) and it
works. For C++ programs, either link statically with `-static`, or ship the
runtime DLLs (`libstdc++-6.dll`, `libgcc_s_seh-1.dll`) next to your `.exe`.

## Updating

Because you took ownership of the folder in step 3, updates need no `sudo`:

```sh
msys-pacman -Syu
```

`msys-pacman` is a small wrapper around a static, prefix-pinned pacman; the
bundled pacman is patched so it never needs root. To pin a fixed snapshot
instead of always getting the latest, point its `[msys-cross]` server at an
archive tag — see [msys-mirror](msys-mirror/README.md).

## Targets

| Target triple | Runtime | Compiler |
|---|---|---|
| `x86_64-w64-mingw32` | msvcrt | GCC 16.1.0 |
| `i686-w64-mingw32` | msvcrt | GCC 16.1.0 |
| `x86_64-w64-mingw32ucrt` | UCRT | GCC 16.1.0 |
| `x86_64-pc-cygwin` | cygwin | GCC 15.2.0 |
| `x86_64-w64-mingw32` (clang64) | UCRT | host clang/lld wrapper |
| `aarch64-w64-mingw32` (clangarm64) | UCRT | host clang/lld wrapper |

binutils 2.46.0 across all targets. The compilers are built with `zig cc`
against a glibc 2.11 ABI (so they run on old and new Linux alike), and the
Windows runtimes (headers, CRT, winpthreads, …) come straight from the official
MSYS2 repositories rather than being rebuilt.

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

Preparing Zig also patches its bundled libc++ (via `scripts/patch_zig_libcxx_oldglibc.sh`,
applying the diffs in `scripts/zig-patches/`) so C++17 aligned `new`/`delete` links on the
old-glibc target — no zig rebuild, no compat object, no extra `-D` flags. The patch is
idempotent and self-verifying; `scripts/test-zig-oldglibc-patch.sh` checks it in a container
against freshly downloaded stable and dev zig.

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
