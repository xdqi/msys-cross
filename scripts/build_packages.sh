#!/bin/bash
# build_packages.sh — build a PKGBUILD without polluting the source tree
#
# Usage:  build_packages.sh <pkg-dir> [makepkg-args...]
#   build_packages.sh msys-cross-gcc -fCd
#   build_packages.sh msys-cross-binutils
#
# Environment (defaults, all under repo root):
#   BUILDDIR  → $TOP/build/<pkg>
#   SRCDEST   → $TOP/sources
#   PKGDEST   → $TOP/repo

set -e

TOP="$(cd "$(dirname "$0")/.." && pwd)"

export SRCDEST="${SRCDEST:-$TOP/sources}"
export PKGDEST="${PKGDEST:-$TOP/repo}"
export LOGDEST="${LOGDEST:-$TOP/build/logs}"

pkg_dir="$1"
shift

export BUILDDIR="${BUILDDIR:-$TOP/build/$pkg_dir}"

mkdir -p "$SRCDEST" "$PKGDEST" "$BUILDDIR" "$LOGDEST"

echo "=== SRCDEST=$SRCDEST"
echo "=== BUILDDIR=$BUILDDIR"
echo "=== PKGDEST=$PKGDEST"
echo "=== Building: pkgs/$pkg_dir"

cd "$TOP/pkgs/$pkg_dir"
exec makepkg "$@"
