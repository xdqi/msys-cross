#!/bin/bash
# Prepare Zig compiler toolchain under build/
#   bash prepare-zig.sh [version]
#
# Output: build/zig-x86_64-linux-<version>/ + build/zig → symlink
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
ZIG_VER="${1:-0.16.0}"
ZIG_DIR="zig-x86_64-linux-$ZIG_VER"
ZIG_TARBALL="$ZIG_DIR.tar.xz"
# Tagged releases live under /download/<ver>/; dev (master) builds under /builds/.
case "$ZIG_VER" in
    *-dev.*) ZIG_URL="https://ziglang.org/builds/$ZIG_TARBALL" ;;
    *)       ZIG_URL="https://ziglang.org/download/$ZIG_VER/$ZIG_TARBALL" ;;
esac
ZIG_INSTALL_DIR="$PROJECT_ROOT/build/zig-x86_64-linux-$ZIG_VER"

mkdir -p "$PROJECT_ROOT/build"

if [ -d "$ZIG_INSTALL_DIR" ]; then
    echo "Zig $ZIG_VER already installed at $ZIG_INSTALL_DIR"
else
    cd "$PROJECT_ROOT/build"
    if [ ! -f "$ZIG_TARBALL" ]; then
        echo "Downloading Zig $ZIG_VER..."
        curl -LO "$ZIG_URL"
    fi
    echo "Extracting..."
    mkdir -p _zig_tmp
    tar xf "$ZIG_TARBALL" -C _zig_tmp
    mv _zig_tmp/"$ZIG_DIR" "$ZIG_INSTALL_DIR"
    rmdir _zig_tmp
    rm -f "$ZIG_TARBALL"
fi

ln -sfn "zig-x86_64-linux-$ZIG_VER" "$PROJECT_ROOT/build/zig"

echo "Zig $ZIG_VER ready:"
"$PROJECT_ROOT/build/zig/zig" version
echo "  ZIG_PATH=$PROJECT_ROOT/build/zig"
