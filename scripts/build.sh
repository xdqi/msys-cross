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
pacman -S --noconfirm --noprogressbar --needed base-devel curl git zstd sudo 2>&1 | tail -2

# Create unprivileged build user (makepkg refuses to run as root)
if ! id builduser >/dev/null 2>&1; then
    useradd -m builduser
    echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi
echo

# ---- Step 1: Prepare zig ----
echo "===== Step 1: Prepare Zig ====="
bash "$SCRIPTS_DIR/prepare-zig.sh"

# ---- Step 2: Prepare bootstrap (MSYS2 sysroots) ----
echo ""
echo "===== Step 2: Prepare bootstrap prefix ====="
bash "$SCRIPTS_DIR/prepare-bootstrap.sh"

# ---- Step 3: Build static deps ----
echo ""
echo "===== Step 3: Build static dependencies ====="
bash "$SCRIPTS_DIR/build_deps.sh"

# ---- Helpers for building PKGBUILDs ----
build_pkg() {
    local pkg_dir="$1" makepkg_args="${2:--fCd --skippgpcheck}"

    # Set up build directories (needed for --packagelist dry-run and actual build)
    export BUILDDIR="$PROJECT_ROOT/build/$pkg_dir"
    mkdir -p "$BUILDDIR" "$PKGDEST" "$SRCDEST" "$LOGDEST"
    chown -R builduser:builduser "$PROJECT_ROOT/build" "$PKGDEST" "$SRCDEST" "$LOGDEST"

    # Compute expected output packages via makepkg --packagelist (dry-run)
    local pkglist
    pkglist=$(cd "$PROJECT_ROOT/pkgs/$pkg_dir" && runuser -u builduser -- makepkg --packagelist 2>/dev/null) || true

    # Skip if all expected packages already exist
    local all_exist=true
    if [ -n "$pkglist" ]; then
        while IFS= read -r p; do
            [ -f "$p" ] || { all_exist=false; break; }
        done <<< "$pkglist"
    else
        all_exist=false
    fi

    if $all_exist; then
        echo ""
        echo "===== Skipping $pkg_dir (already built) ====="
        while IFS= read -r f; do echo "  $(basename "$f")"; done <<< "$pkglist"
        return 0
    fi

    echo ""
    echo "===== Building $pkg_dir ====="
    cd "$PROJECT_ROOT/pkgs/$pkg_dir"
    runuser -u builduser -- makepkg $makepkg_args
}

install_local() {
    local pattern="$1"
    echo "--- Installing $pattern ---"
    mkdir -p "$INSTALL_PREFIX/var/lib/pacman"
    pacman -Udd --noconfirm --overwrite='*' --root="$INSTALL_PREFIX" "$PKGDEST"/$pattern 2>&1 | tail -3
}

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

# Binutils (GCC needs as/ld in PATH)
build_pkg "msys-cross-binutils"

install_local "msys-cross-binutils-common-*.pkg.tar.*"
install_local "msys-cross-mingw64-binutils-*.pkg.tar.*"
install_local "msys-cross-mingw32-binutils-*.pkg.tar.*"
install_local "msys-cross-ucrt64-binutils-*.pkg.tar.*"
install_local "msys-cross-cygwin-binutils-*.pkg.tar.*"

# GCC (mingw64/32/ucrt)
build_pkg "msys-cross-gcc"

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
