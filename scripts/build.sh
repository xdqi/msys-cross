#!/bin/bash
# Build all msys2-cross packages from scratch.
#   bash scripts/build.sh
#
# Prerequisites: base-devel, curl, git, zstd (installed automatically in container)
# Mounts: pkgs/ (ro), scripts/ (ro), deps/ (ro), repo/ (rw output)
# Everything else is downloaded/built inside the container.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Paths — writable destinations are placed under build/
export PKGDEST="${PKGDEST:-$PROJECT_ROOT/repo}"
export SRCDEST="${SRCDEST:-$PROJECT_ROOT/build/sources}"
export LOGDEST="${LOGDEST:-$PROJECT_ROOT/build/logs}"
export DEPS_INSTALL="${DEPS_INSTALL:-$PROJECT_ROOT/build/deps-install}"
export DEPS="${DEPS:-$DEPS_INSTALL}"
export BOOTSTRAP_PREFIX="${BOOTSTRAP_PREFIX:-$PROJECT_ROOT/build/bootstrap-prefix}"
export INSTALL_PREFIX="${INSTALL_PREFIX:-$PROJECT_ROOT/build/install-prefix}"
export ZIG_PATH="${ZIG_PATH:-$PROJECT_ROOT/build/zig}"
export DEPS_CACHE="$PROJECT_ROOT/deps"    # ro mount for cached tarballs
export JOBS="${JOBS:-$(nproc)}"

mkdir -p "$PKGDEST" "$SRCDEST" "$LOGDEST" "$DEPS_INSTALL" "$INSTALL_PREFIX" "$PROJECT_ROOT/build"

echo "=== msys2-cross build ==="
echo "PKGDEST:    $PKGDEST"
echo "BOOTSTRAP:  $BOOTSTRAP_PREFIX"
echo "INSTALL:    $INSTALL_PREFIX"
echo "DEPS:       $DEPS"
echo "ZIG_PATH:   $ZIG_PATH"
echo

# Cross-binutils from install prefix must be in PATH for GCC builds
export PATH="$INSTALL_PREFIX/bin:$PATH"

# ---- Step 0: Install host build tools ----
echo "=== Installing host build tools ==="
pacman -Syu --noconfirm --noprogressbar 2>&1 | tail -2
# llvm: provides llvm-nm, which build_deps.sh uses as NM for cross targets — the host
# GNU nm can't read a cross object (e.g. arm64 Mach-O), which breaks gmp's configure.
# (Arch ships it at /usr/bin/llvm-nm; build_deps.sh's `command -v llvm-nm` finds it.)
pacman -S --noconfirm --noprogressbar --needed base-devel curl git zstd sudo llvm 2>&1 | tail -2

# Create unprivileged build user (makepkg refuses to run as root)
if ! id builduser >/dev/null 2>&1; then
    useradd -m builduser
    echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi
echo

# Shared build helpers: run_as_builduser, build_pkg, install_local.
source "$SCRIPTS_DIR/build-common.sh"

# ---- Step 1: Prepare zig ----
echo "===== Step 1: Prepare Zig ====="
bash "$SCRIPTS_DIR/prepare-zig.sh"

# ---- Step 2: Prepare build sysroots (MSYS2 target headers/libs) ----
echo ""
echo "===== Step 2: Prepare build sysroots ====="
bash "$SCRIPTS_DIR/prepare-build-sysroot.sh"

# ---- Step 3: Build static deps ----
# Built as builduser (see run_as_builduser) so the sccache server is the same uid
# as the gcc/binutils phase.
echo ""
echo "===== Step 3: Build static dependencies ====="
run_as_builduser bash "$SCRIPTS_DIR/build_deps.sh"

# build_pkg / install_local now live in build-common.sh (sourced above).

# ---- Step 4: Build packages in dependency order ----
echo ""
echo "===== Step 4: Build packages ====="

# Foundation packages
build_pkg "msys-cross-filesystem"
build_pkg "msys-cross-ca-certificates"
build_pkg "msys-cross-pacman"

install_local "msys-cross-filesystem-*.pkg.tar.*"
install_local "msys-cross-ca-certificates-*.pkg.tar.*"
install_local "msys-cross-pacman-*.pkg.tar.*"

# Cross pkg-config wrappers
build_pkg "msys-cross-pkgconfig"
install_local "msys-cross-pkgconfig-*.pkg.tar.*"

# Binutils (GCC needs as/ld in PATH). One makepkg run per target so each gets its
# own per-target -debug package (msys-cross-<target>-binutils-debug); the shared
# binutils-common rides the mingw64 run. _MSYS_CROSS_TARGET is exported for the
# whole iteration (build_pkg + run_as_builduser pick it up); unset after the loop.
for _t in mingw64 mingw32 ucrt64 cygwin; do
    export _MSYS_CROSS_TARGET="$_t"
    build_pkg "msys-cross-binutils"
done
unset _MSYS_CROSS_TARGET

install_local "msys-cross-binutils-common-*.pkg.tar.*"
install_local "msys-cross-mingw64-binutils-*.pkg.tar.*"
install_local "msys-cross-mingw32-binutils-*.pkg.tar.*"
install_local "msys-cross-ucrt64-binutils-*.pkg.tar.*"
install_local "msys-cross-cygwin-binutils-*.pkg.tar.*"

# GCC (mingw64/32/ucrt). One makepkg run per target so each gets its own per-target
# -debug package (msys-cross-<target>-gcc-debug); a target's -gcc and -gcc-fortran
# sub-packages share that one -debug. mingw32 has no fortran sub-package.
for _t in mingw64 mingw32 ucrt64; do
    export _MSYS_CROSS_TARGET="$_t"
    build_pkg "msys-cross-gcc"
done
unset _MSYS_CROSS_TARGET

install_local "msys-cross-mingw64-gcc-*.pkg.tar.*"
install_local "msys-cross-mingw32-gcc-*.pkg.tar.*"
install_local "msys-cross-ucrt64-gcc-*.pkg.tar.*"

# Cygwin GCC
build_pkg "msys-cross-cygwin-gcc"

install_local "msys-cross-cygwin-gcc-*.pkg.tar.*"

# ---- Step 5: Create repo database ----
echo ""
echo "===== Step 5: Repo database ====="
rm -f "$PKGDEST/msys-cross.db" "$PKGDEST/msys-cross.db.tar.gz" "$PKGDEST/msys-cross.files" "$PKGDEST/msys-cross.files.tar.gz"

for pkg in "$PKGDEST"/*.pkg.tar.*; do
    [ -f "$pkg" ] || continue
    repo-add "$PKGDEST/msys-cross.db.tar.gz" "$pkg"
done

# ---- Step 6: Build installer ----
echo ""
echo "===== Step 6: Build installer ====="
export INSTALLER_DIR="${INSTALLER_DIR:-$PROJECT_ROOT/installer}"
bash "$SCRIPTS_DIR/build_installer.sh"

echo ""
echo "===== Build complete ====="
echo "Repo: $PKGDEST"
ls "$PKGDEST"/*.pkg.tar.* 2>/dev/null | while read -r f; do
    echo "  $(basename "$f")"
done
echo ""
echo "Database:"
ls -la "$PKGDEST/msys-cross.db.tar.gz"
