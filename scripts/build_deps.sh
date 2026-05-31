#!/bin/bash
# Build gmp, mpfr, mpc, isl, zlib, zstd as static libs.
# Downloads source tarballs if not already cached in DEPS_CACHE.
# Creates .so->.a symlinks for zig's no_fallback linker.
#
# Versions (customizable via environment):
#   GMP_VER MPFR_VER MPC_VER ISL_VER ZLIB_VER ZSTD_VER
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

GMP_VER="${GMP_VER:-6.3.0}"
MPFR_VER="${MPFR_VER:-4.2.2}"
MPC_VER="${MPC_VER:-1.3.1}"
ISL_VER="${ISL_VER:-0.27}"
ZLIB_VER="${ZLIB_VER:-1.3.2}"
ZSTD_VER="${ZSTD_VER:-1.5.7}"

PREFIX="${DEPS_INSTALL:-$PROJECT_ROOT/deps/install}"
DEPS_CACHE="${DEPS_CACHE:-$PROJECT_ROOT/deps}"
JOBS="${JOBS:-$(nproc)}"

# Use zigcc/zigc++ wrappers from scripts/
source "$SCRIPTS_DIR/msys-cross-common.sh"
setup_zig_env
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
export LDFLAGS=""

mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/bin"

# ---- URL map for source tarballs ----
declare -A DEPS_URL
DEPS_URL[gmp-${GMP_VER}.tar.xz]="https://gmplib.org/download/gmp/gmp-${GMP_VER}.tar.xz"
DEPS_URL[mpfr-${MPFR_VER}.tar.xz]="https://www.mpfr.org/mpfr-${MPFR_VER}/mpfr-${MPFR_VER}.tar.xz"
DEPS_URL[mpc-${MPC_VER}.tar.gz]="https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz"
DEPS_URL[isl-${ISL_VER}.tar.xz]="https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz"
DEPS_URL[zlib-${ZLIB_VER}.tar.xz]="https://zlib.net/zlib-${ZLIB_VER}.tar.xz"
DEPS_URL[zstd-${ZSTD_VER}.tar.gz]="https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz"

# Make a writable working copy of source tarballs
WORK_DEPS="$PROJECT_ROOT/build/.deps-src"
mkdir -p "$WORK_DEPS"

get_tarball() {
    local fn="$1"
    if [ -f "$WORK_DEPS/$fn" ]; then return 0; fi
    if [ -f "$DEPS_CACHE/$fn" ]; then
        cp "$DEPS_CACHE/$fn" "$WORK_DEPS/$fn"
        return 0
    fi
    local url="${DEPS_URL[$fn]:-}"
    if [ -z "$url" ]; then
        echo "ERROR: No URL for $fn"
        return 1
    fi
    echo "  Downloading $fn..."
    curl -sLo "$WORK_DEPS/$fn" "$url"
}

cd "$WORK_DEPS"
TARBALLS=(
    "gmp-${GMP_VER}.tar.xz"
    "mpfr-${MPFR_VER}.tar.xz"
    "mpc-${MPC_VER}.tar.gz"
    "isl-${ISL_VER}.tar.xz"
    "zlib-${ZLIB_VER}.tar.xz"
    "zstd-${ZSTD_VER}.tar.gz"
)
for a in "${TARBALLS[@]}"; do
    get_tarball "$a"
    d="${a%.tar.*}"; [ -d "$d" ] || tar xf "$a"
done

do_build() {
    local name="$1" dir="$2" extra="$3"
    echo "=== $name ==="
    mkdir -p "$WORK_DEPS/${name}-build" && cd "$WORK_DEPS/${name}-build"
    find . -name config.cache -delete 2>/dev/null || true
    ../$dir/configure --prefix="$PREFIX" --enable-static --disable-shared \
        --build=x86_64-linux-gnu --host=x86_64-linux-gnu $extra
    make -j"$JOBS" && make install
}

do_build gmp  "gmp-${GMP_VER}" ""
do_build mpfr "mpfr-${MPFR_VER}" "--with-gmp=$PREFIX --disable-float128"
do_build mpc  "mpc-${MPC_VER}" "--with-gmp=$PREFIX --with-mpfr=$PREFIX"
do_build isl  "isl-${ISL_VER}"  "--with-gmp-prefix=$PREFIX"

echo "=== zlib ==="
mkdir -p "$WORK_DEPS/zlib-build" && cd "$WORK_DEPS/zlib-build"
CFLAGS="-O2 -fPIC" ../zlib-${ZLIB_VER}/configure --prefix="$PREFIX" --static
make -j"$JOBS" && make install

echo "=== zstd ==="
cd "$WORK_DEPS/zstd-${ZSTD_VER}/lib"
CFLAGS="-O2 -fPIC" make -j"$JOBS" libzstd.a
cp libzstd.a "$PREFIX/lib/"
cp zstd.h zdict.h zstd_errors.h "$PREFIX/include/"

# .so->.a symlinks for zig's no_fallback linker
for lib in gmp mpfr mpc isl z zstd; do
    ln -sf "lib${lib}.a" "$PREFIX/lib/lib${lib}.so"
done

echo "=== deps done ==="
ls -la "$PREFIX/lib/lib"{gmp,mpfr,mpc,isl,z,zstd}.a
