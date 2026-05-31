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
_pacman -Sy \
    mingw-w64-x86_64-headers mingw-w64-x86_64-crt \
    mingw-w64-x86_64-winpthreads mingw-w64-x86_64-gcc-libs \
    mingw-w64-x86_64-zlib mingw-w64-x86_64-windows-default-manifest

echo "=== Installing mingw32 sysroot ==="
_pacman -Sy \
    mingw-w64-i686-headers mingw-w64-i686-crt \
    mingw-w64-i686-winpthreads mingw-w64-i686-gcc-libs \
    mingw-w64-i686-zlib mingw-w64-i686-windows-default-manifest

echo "=== Installing ucrt64 sysroot ==="
_pacman -Sy \
    mingw-w64-ucrt-x86_64-headers mingw-w64-ucrt-x86_64-crt \
    mingw-w64-ucrt-x86_64-winpthreads mingw-w64-ucrt-x86_64-gcc-libs \
    mingw-w64-ucrt-x86_64-zlib mingw-w64-ucrt-x86_64-windows-default-manifest

echo "=== Installing cygwin/msys sysroot ==="
_pacman -Sy \
    msys2-runtime-devel msys2-w32api-headers msys2-w32api-runtime

echo
echo "=== Bootstrap prefix ready ==="
echo "  BOOTSTRAP_PREFIX=$OUT"
echo "  $(ls -d "$OUT"/mingw64 "$OUT"/mingw32 "$OUT"/ucrt64 "$OUT"/usr 2>/dev/null | xargs -I{} basename {})"
