#!/bin/bash
# Prepare the MSYS2 target sysroots used at build time (headers/libs/binutils
# for mingw64/mingw32/ucrt64/cygwin). This is the cross-compiler's *target*
# system — NOT the user-facing bootstrap.tar.xz (that is built by
# build_installer.sh from the finished packages).
# Uses native pacman to install the mingw64/mingw32/ucrt64/msys sysroots.
#
# Output: $BOOTSTRAP_PREFIX (default build/bootstrap-prefix)/{mingw64,mingw32,ucrt64,usr}
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
OUT="${BOOTSTRAP_PREFIX:-$PROJECT_ROOT/build/bootstrap-prefix}"
MIRROR="${MSYS2_MIRROR:-https://repo.msys2.org}"

echo "=== msys2-cross bootstrap prefix setup ==="
echo "Output: $OUT"
echo

rm -rf "$OUT"
mkdir -p "$OUT/var/lib/pacman" "$OUT/etc/pacman.d"

cat > "$OUT/etc/pacman.d/pacman.conf" <<ENDCONF
[mingw64]
Server = ${MIRROR}/mingw/mingw64/
SigLevel = Never

[mingw32]
Server = ${MIRROR}/mingw/mingw32/
SigLevel = Never

[ucrt64]
Server = ${MIRROR}/mingw/ucrt64/
SigLevel = Never

[msys]
Server = ${MIRROR}/msys/x86_64/
SigLevel = Never
ENDCONF

_pacman() {
    echo "  -> pacman $*"
    pacman \
        --root="$OUT" \
        --config="$OUT/etc/pacman.d/pacman.conf" \
        --dbpath="$OUT/var/lib/pacman" \
        --noconfirm "$@"
}

echo "=== Installing mingw64 sysroot ==="
# Also install the upstream gcc + gcc-fortran packages: msys-cross-gcc builds only
# the host compiler (make all-gcc) and sources the TARGET runtime libs (libgcc,
# libstdc++, libgfortran, crt, C++ headers) by copying them out of this sysroot
# via `pacman -Ql` (see scripts/extract-target-libs.sh::copy_sysroot_pkg). Letting
# pacman install them resolves the right version/triple/layout automatically.
_pacman -Sy \
    mingw-w64-x86_64-headers mingw-w64-x86_64-crt \
    mingw-w64-x86_64-winpthreads mingw-w64-x86_64-gcc-libs \
    mingw-w64-x86_64-zlib mingw-w64-x86_64-windows-default-manifest \
    mingw-w64-x86_64-gcc mingw-w64-x86_64-gcc-fortran

echo "=== Installing mingw32 sysroot ==="
# NOTE: MSYS2 no longer ships mingw-w64-i686-gcc-fortran (32-bit mingw is being
# retired upstream; the mingw32 repo has the i686 gcc but no gcc-fortran). pacman
# aborts the WHOLE transaction on a single "target not found", and this script runs
# under `set -e`, so we must NOT request the missing package — we install only
# mingw-w64-i686-gcc here. The msys-cross-mingw32-gcc-fortran subpackage's
# copy_sysroot_pkg call will then find nothing to copy (it just reports 0 files),
# leaving the 32-bit Fortran subpackage effectively empty / host-driver-only.
_pacman -Sy \
    mingw-w64-i686-headers mingw-w64-i686-crt \
    mingw-w64-i686-winpthreads mingw-w64-i686-gcc-libs \
    mingw-w64-i686-zlib mingw-w64-i686-windows-default-manifest \
    mingw-w64-i686-gcc

echo "=== Installing ucrt64 sysroot ==="
_pacman -Sy \
    mingw-w64-ucrt-x86_64-headers mingw-w64-ucrt-x86_64-crt \
    mingw-w64-ucrt-x86_64-winpthreads mingw-w64-ucrt-x86_64-gcc-libs \
    mingw-w64-ucrt-x86_64-zlib mingw-w64-ucrt-x86_64-windows-default-manifest \
    mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gcc-fortran

echo "=== Installing cygwin/msys sysroot ==="
_pacman -Sy \
    msys2-runtime-devel msys2-w32api-headers msys2-w32api-runtime

echo
echo "=== Bootstrap prefix ready ==="
echo "  BOOTSTRAP_PREFIX=$OUT"
echo "  $(ls -d "$OUT"/mingw64 "$OUT"/mingw32 "$OUT"/ucrt64 "$OUT"/usr 2>/dev/null | xargs -I{} basename {})"
