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

# ---- Bootstrap tarball ----
# The single user-facing manual download: the installer tree wrapped under a
# top-level msys2-cross/ dir so it extracts to /opt/msys2-cross. Emitted into
# PKGDEST so it is published alongside the repo (release asset / mirror).
BOOTSTRAP_TARBALL="${BOOTSTRAP_TARBALL:-$PKGDEST/bootstrap.tar.xz}"
echo "=== Packing bootstrap tarball: $BOOTSTRAP_TARBALL ==="
tar -cJf "$BOOTSTRAP_TARBALL" \
    --transform 's,^\.,msys2-cross,' \
    --show-transformed-names \
    -C "$INSTALLER_DIR" . >/dev/null
echo "Bootstrap tarball: $(du -h "$BOOTSTRAP_TARBALL" | cut -f1)"
