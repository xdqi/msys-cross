#!/usr/bin/env bash
# makepkg download agent for https:// sources (installed by makepkg-mirrors.conf).
#
#   dlagent-https.sh <output> <url>
#
# Same curl flags as Arch's stock https agent, plus a connect timeout. A GNU
# release URL (https://ftp.gnu.org/gnu/...) is tried on the kernel.org GNU
# mirror first: on 2026-10-06 ftp.gnu.org refused connections from GitHub
# runners for hours (run 37450353873 lost binutils-2.47.tar.xz), while
# mirrors.kernel.org served. makepkg still checks every file against the
# PKGBUILD's sha256sums, so a mirror can't slip in a different tarball.
set -u
out="$1" url="$2"

urls=("$url")
case "$url" in
    https://ftp.gnu.org/gnu/*)
        urls=("https://mirrors.kernel.org/gnu/${url#https://ftp.gnu.org/gnu/}" "$url") ;;
esac

for u in "${urls[@]}"; do
    if curl -qgb "" -fLC - --connect-timeout 30 --retry 3 --retry-delay 3 -o "$out" "$u"; then
        exit 0
    fi
    echo "dlagent-https: $u failed" >&2
    # A partial body from one mirror must not be resumed from another.
    rm -f "$out"
done
exit 1
