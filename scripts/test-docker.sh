#!/bin/bash
# Single-toolchain Docker test: one distro × one toolchain
# Usage: bash test-docker.sh <centos7|debian8> <mingw64|mingw32|ucrt64|cygwin>
set -euo pipefail

DISTRO="${1:?Usage: $0 <centos7|debian8> <mingw64|mingw32|ucrt64|cygwin>}"
TOOLCHAIN="${2:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$PROJECT_ROOT/repo"
INSTALLER_DIR="$PROJECT_ROOT/installer"
DOCKER_NAME="msys2-cross-${DISTRO}-${TOOLCHAIN}"

# ---- Toolchain map ----
case "$TOOLCHAIN" in
    mingw64)
        GCC_PKG="msys-cross-mingw64-gcc"
        TARGET="x86_64-w64-mingw32"
        MSYS_SUBDIR="mingw64"
        LANGS="c c++ fortran"
        EXTRA_SETUP=""
        ;;
    mingw32)
        GCC_PKG="msys-cross-mingw32-gcc"
        TARGET="i686-w64-mingw32"
        MSYS_SUBDIR="mingw32"
        LANGS="c c++ fortran"
        EXTRA_SETUP=""
        ;;
    ucrt64)
        GCC_PKG="msys-cross-ucrt64-gcc"
        TARGET="x86_64-w64-mingw32ucrt"
        MSYS_SUBDIR="ucrt64"
        LANGS="c c++ fortran"
        EXTRA_SETUP=""
        ;;
    cygwin)
        GCC_PKG="msys-cross-cygwin-gcc"
        TARGET="x86_64-pc-cygwin"
        MSYS_SUBDIR="usr"
        LANGS="c c++"
        EXTRA_SETUP="
# GCC expects \$sysroot/include and \$sysroot/lib (not \$sysroot/usr/{include,lib})
ln -sf usr/include \"\$PREFIX/include\" 2>/dev/null || true
ln -sf usr/lib \"\$PREFIX/lib\" 2>/dev/null || true
ln -sf . \"\$PREFIX/usr/cygwin\" 2>/dev/null || true
# w32api import libs live in usr/lib/w32api/; linker needs them in usr/lib/
for lib in \"\$PREFIX/usr/lib/w32api/\"*.a; do
    [ -f \"\$lib\" ] && ln -sf \"w32api/\$(basename \"\$lib\")\" \"\$PREFIX/usr/lib/\$(basename \"\$lib\")\" 2>/dev/null || true
done
"
        ;;
    *) echo "Unknown toolchain: $TOOLCHAIN"; exit 1 ;;
esac

case "$DISTRO" in
    centos7) DOCKER_IMAGE="centos:7" ;;
    debian8) DOCKER_IMAGE="debian:jessie" ;;
    *) echo "Unknown distro: $DISTRO"; exit 1 ;;
esac

echo "=== msys2-cross ${DISTRO} ${TOOLCHAIN} Test ==="
echo "Target: $TARGET ($GCC_PKG)"
echo

docker rm -f "$DOCKER_NAME" 2>/dev/null || true

docker run -d --name "$DOCKER_NAME" \
    -v "$REPO_DIR:/repo:ro" \
    -v "$INSTALLER_DIR:/installer:ro" \
    "$DOCKER_IMAGE" \
    sleep infinity

docker cp "$INSTALLER_DIR"/. "$DOCKER_NAME:/opt/msys2-cross/"
docker exec "$DOCKER_NAME" chmod +x /opt/msys2-cross/libexec/pacman-static /opt/msys2-cross/bin/msys-pacman

docker exec "$DOCKER_NAME" bash -c "
set -e
export PATH=\"/opt/msys2-cross/bin:\$PATH\"
PREFIX=/opt/msys2-cross

case '$DISTRO' in
    debian8)
        echo 'deb http://archive.debian.org/debian jessie main' > /etc/apt/sources.list
        echo 'deb http://archive.debian.org/debian-security jessie/updates main' >> /etc/apt/sources.list
        apt-get update -o Acquire::Check-Valid-Until=false 2>&1 | tail -3
        apt-get install -y --force-yes file 2>&1 | tail -3 || true
        ;;
    centos7)
        for f in /etc/yum.repos.d/*.repo; do
            sed -i 's|^mirrorlist=|#mirrorlist=|g; s|^#baseurl=http://mirror|baseurl=http://vault|g; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \"\$f\"
        done
        yum install -y file 2>&1 | tail -3 || true
        ;;
esac

mkdir -p /etc/ssl/certs
[ -f /etc/ssl/certs/ca-certificates.crt ] || ln -sf \"\$PREFIX/etc/ssl/certs/ca-certificates.crt\" /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true

echo
echo '=== Verify bootstrap ==='
/opt/msys2-cross/libexec/pacman-static -V
/opt/msys2-cross/bin/msys-pacman -V || true

echo
echo '=== Install toolchain: $GCC_PKG ==='
yes | /opt/msys2-cross/bin/msys-pacman -Sy \
    msys-cross-filesystem \
    $GCC_PKG

echo
echo '=== Verify toolchain ==='
echo -n \"$TARGET: \"
ls \"\$PREFIX/bin/$TARGET-gcc\" 2>/dev/null && echo 'OK' || echo 'MISSING'

echo
echo '=== Sysroot setup ==='
$EXTRA_SETUP

echo
echo '=== Test compilation ==='
cat > /tmp/test.c <<'CEOF'
int main() { return 42; }
CEOF
cat > /tmp/test.cc <<'CCEOF'
#include <iostream>
int main() { std::cout << \"hello\" << std::endl; return 0; }
CCEOF
cat > /tmp/test.f90 <<'FEOF'
end program
FEOF

tests_fail=0

test_compile() {
    local label=\"\$1\" compiler=\"\$2\" src=\"\$3\" out=\"\$4\"
    echo -n \"  \$label: \"
    if \"\$PREFIX/bin/\${compiler}\" -o \"\$out\" \"\$src\" 2>&1; then
        if file \"\$out\" 2>/dev/null | grep -q 'PE32'; then
            echo \"OK (\$(file \"\$out\" | cut -d, -f1))\"
        else
            echo 'OK'
        fi
    else
        echo 'FAIL'
        tests_fail=\$((tests_fail+1))
    fi
}

for lang in $LANGS; do
    case \"\$lang\" in
        c)
            test_compile 'C       ' ${TARGET}-gcc      /tmp/test.c   /tmp/tc.exe
            ;;
        c++)
            test_compile 'C++     ' ${TARGET}-g++      /tmp/test.cc  /tmp/tcpp.exe
            ;;
        fortran)
            test_compile 'Fortran ' ${TARGET}-gfortran /tmp/test.f90 /tmp/tf.exe
            ;;
    esac
done

echo
echo '=== Results ==='
echo \"Failures: \$tests_fail\"
[ \"\$tests_fail\" -eq 0 ] && echo 'ALL TESTS PASSED' || echo 'SOME TESTS FAILED'
"

docker rm -f "$DOCKER_NAME"
echo "=== Done: ${DISTRO}/${TOOLCHAIN} ==="
