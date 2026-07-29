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

# Per-target install prefix so each ZIG_TARGET's arch keeps its own static .a
# (Linux x86_64 and macOS arm64 deps coexist). DEPS_INSTALL overrides explicitly.
# ZIG_TARGET comes from env-<target>.sh (the marker guard in msys-cross-common.sh,
# sourced below, asserts that env was loaded).
PREFIX="${DEPS_INSTALL:-$PROJECT_ROOT/deps/install-$ZIG_TARGET}"
DEPS_CACHE="${DEPS_CACHE:-$PROJECT_ROOT/deps}"
JOBS="${JOBS:-$(nproc)}"

# Use zigcc/zigc++ wrappers from scripts/
source "$SCRIPTS_DIR/msys-cross-common.sh"
setup_zig_env
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
export LDFLAGS=""

# Some deps' configure (gmp) inspects an object with NM; the host's GNU nm can't read
# a cross object (e.g. arm64 Mach-O → "file format not recognized"). zig has no `nm`,
# so point NM at an llvm-nm (reads every format LLVM emits) when one is available.
# Only matters for cross targets; on a native Linux build the host nm works too.
if [ -z "${NM:-}" ]; then
    # `|| true` inside the $(): when llvm-nm is absent AND the ls globs match nothing, ls
    # exits 2; under pipefail that would abort the script via set -e, defeating the graceful
    # fall-through to host nm. Keep it non-fatal so $_llvm_nm just ends up empty.
    _llvm_nm="$(command -v llvm-nm 2>/dev/null || ls /usr/lib/llvm-*/bin/llvm-nm /usr/bin/llvm-nm-* 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$_llvm_nm" ] && export NM="$_llvm_nm"
fi

mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/bin"

# ---- URL map for source tarballs ----
# Each entry may list multiple space-separated URLs; they are tried in order.
# Primary upstreams can be flaky from CI (gmplib.org has timed out from GitHub
# runners), so a GNU/GCC-infrastructure mirror is listed as a fallback.
declare -A DEPS_URL
DEPS_URL[gmp-${GMP_VER}.tar.xz]="https://gmplib.org/download/gmp/gmp-${GMP_VER}.tar.xz https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz https://gcc.gnu.org/pub/gcc/infrastructure/gmp-${GMP_VER}.tar.xz"
DEPS_URL[mpfr-${MPFR_VER}.tar.xz]="https://www.mpfr.org/mpfr-${MPFR_VER}/mpfr-${MPFR_VER}.tar.xz https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz"
DEPS_URL[mpc-${MPC_VER}.tar.gz]="https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz https://www.multiprecision.org/downloads/mpc-${MPC_VER}.tar.gz"
DEPS_URL[isl-${ISL_VER}.tar.xz]="https://libisl.sourceforge.io/isl-${ISL_VER}.tar.xz https://gcc.gnu.org/pub/gcc/infrastructure/isl-${ISL_VER}.tar.bz2"
# zlib: GitHub release first — content-addressed per tag, always serves the exact
# version. The zlib.net top-level path is intentionally NOT used: it rolls to whatever
# is "current" and intermittently answers HTTP 200 with an HTML index page instead of
# the tarball, which curl -f accepts and only blows up later at extract time. Keep the
# zlib.net fossils path as a last-ditch fallback (populated once a version ages out);
# validate_archive() below rejects any HTML-200 body regardless of which mirror served it.
DEPS_URL[zlib-${ZLIB_VER}.tar.xz]="https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.xz https://www.zlib.net/fossils/zlib-${ZLIB_VER}.tar.xz"
DEPS_URL[zstd-${ZSTD_VER}.tar.gz]="https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz"

# Make a writable working copy of source tarballs
WORK_DEPS="$PROJECT_ROOT/build/.deps-src"
mkdir -p "$WORK_DEPS"

# Robust download: bounded timeouts + retries, fail on HTTP errors, and try each
# fallback URL in turn. Avoids the unbounded hang that produced curl exit 28 in
# CI when the primary upstream stalls.
fetch_url() {
    local url="$1" dest="$2"
    curl -fL --connect-timeout 20 --max-time 600 \
        --retry 3 --retry-delay 3 --retry-all-errors \
        -o "$dest" "$url"
}

# Verify a downloaded file really is the compressed archive its name claims. A mirror
# can answer HTTP 200 with an HTML error/index page (zlib.net has done this repeatedly),
# which curl -f happily accepts; without this check that garbage passes as a tarball and
# only dies at `tar xf` time, aborting the whole build instead of failing over to the
# next mirror. Match magic bytes against the extension.
validate_archive() {
    local f="$1" magic
    magic=$(head -c6 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$f" in
        *.tar.xz|*.txz)   [[ "$magic" == fd377a585a* ]] ;;   # xz:   FD 37 7A 58 5A 00
        *.tar.gz|*.tgz)   [[ "$magic" == 1f8b* ]] ;;         # gzip: 1F 8B
        *.tar.bz2|*.tbz2) [[ "$magic" == 425a68* ]] ;;       # bzip2: 'BZh'
        *)                return 0 ;;                         # unknown ext: skip check
    esac
}

get_tarball() {
    local fn="$1"
    if [ -f "$WORK_DEPS/$fn" ]; then return 0; fi
    if [ -f "$DEPS_CACHE/$fn" ]; then
        cp "$DEPS_CACHE/$fn" "$WORK_DEPS/$fn"
        return 0
    fi
    local urls="${DEPS_URL[$fn]:-}"
    if [ -z "$urls" ]; then
        echo "ERROR: No URL for $fn"
        return 1
    fi
    local url
    for url in $urls; do
        echo "  Downloading $fn from $url ..."
        if fetch_url "$url" "$WORK_DEPS/$fn.part" && validate_archive "$WORK_DEPS/$fn.part"; then
            mv "$WORK_DEPS/$fn.part" "$WORK_DEPS/$fn"
            return 0
        fi
        echo "  ... failed or not a valid archive, trying next mirror"
        rm -f "$WORK_DEPS/$fn.part"
    done
    echo "ERROR: all mirrors failed for $fn"
    return 1
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
    local name="$1" dir="$2" extra="$3" make_tgt="${4:-}" install_tgt="${5:-install}"
    echo "=== $name ==="
    mkdir -p "$WORK_DEPS/${name}-build" && cd "$WORK_DEPS/${name}-build"
    find . -name config.cache -delete 2>/dev/null || true
    # host/build overridable (war-future, consistent with the PKGBUILDs): host != build
    # puts autoconf in cross mode so it won't RUN the (non-native) conftest.
    ../$dir/configure --prefix="$PREFIX" --enable-static --disable-shared \
        --build="$MSYS_CROSS_BUILD" \
        --host="$MSYS_CROSS_HOST" $extra
    # make_tgt lets a dep build ONLY its library (skip noinst test programs) — needed
    # for isl, whose C++ test progs pull legacy Mach-O libtool link flags on darwin and
    # are pure waste here. Default (empty) = full `all` for the rest.
    make -j"$JOBS" $make_tgt && make $install_tgt
}

do_build gmp  "gmp-${GMP_VER}" ""
do_build mpfr "mpfr-${MPFR_VER}" "--with-gmp=$PREFIX --disable-float128"
do_build mpc  "mpc-${MPC_VER}" "--with-gmp=$PREFIX --with-mpfr=$PREFIX"
# isl: build only libisl.la + install just the lib and headers (its noinst test progs
# are unneeded and trip zig's ld on a darwin host).
do_build isl  "isl-${ISL_VER}"  "--with-gmp-prefix=$PREFIX" \
    "gitversion.h libisl.la" "install-libLTLIBRARIES install-nodist_pkgincludeHEADERS install-data"

echo "=== zlib ==="
mkdir -p "$WORK_DEPS/zlib-build" && cd "$WORK_DEPS/zlib-build"
CFLAGS="-O2 -fPIC" ../zlib-${ZLIB_VER}/configure --prefix="$PREFIX" --static
make -j"$JOBS" && make install

echo "=== zstd ==="
cd "$WORK_DEPS/zstd-${ZSTD_VER}/lib"
CFLAGS="-O2 -fPIC" make -j"$JOBS" libzstd.a
# install-pc emits lib/pkgconfig/libzstd.pc (needed by pkg-config consumers such as
# the from-source pacman build); install-static + install-includes give libzstd.a +
# headers — same artifacts the old manual cp produced, plus the .pc.
make PREFIX="$PREFIX" install-pc install-static install-includes

# .so->.a symlinks for zig's no_fallback linker
for lib in gmp mpfr mpc isl z zstd; do
    ln -sf "lib${lib}.a" "$PREFIX/lib/lib${lib}.so"
done

echo "=== deps done ==="
ls -la "$PREFIX/lib/lib"{gmp,mpfr,mpc,isl,z,zstd}.a

# Reclaim the extracted source + *-build object trees under $WORK_DEPS — the static .a are
# now installed into $PREFIX, so these are pure scratch. The `*/` glob matches only the
# subdirectories (source + build trees); the downloaded *.tar.* tarballs are plain files and
# are kept, so a re-run still skips the re-download. Without this the whole tree (source +
# intermediate .o) gets baked into the prep image, which only needs deps/install-*/ at runtime.
echo "--- Cleaning deps scratch trees (keeping cached tarballs) ---"
shopt -s nullglob
for _d in "$WORK_DEPS"/*/; do
    rm -rf "$_d"
done
shopt -u nullglob
