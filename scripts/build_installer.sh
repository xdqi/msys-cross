#!/bin/bash
# Build distributable installer from built repo packages.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

PKGDEST="${PKGDEST:-$PROJECT_ROOT/repo}"
INSTALLER_DIR="${INSTALLER_DIR:-$PROJECT_ROOT/installer}"

echo "=== Building installer: $INSTALLER_DIR ==="

rm -rf "$INSTALLER_DIR"
mkdir -p "$INSTALLER_DIR/var/lib/pacman"

# --config: pacman with --root looks for $root/etc/pacman.conf which doesn't
# exist yet. Point to the pacman.conf from the msys-cross-pacman source dir.
PACMAN_CONF="$PROJECT_ROOT/pkgs/msys-cross-pacman/pacman.conf"
pacman -Udd --noconfirm --root="$INSTALLER_DIR" --config "$PACMAN_CONF" \
    "$PKGDEST"/msys-cross-filesystem-*.pkg.tar.* \
    "$PKGDEST"/msys-cross-ca-certificates-*.pkg.tar.* \
    "$PKGDEST"/msys-cross-pacman-*.pkg.tar.*

echo "Installer created at $INSTALLER_DIR"
