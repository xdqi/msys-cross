# msys-cross extract-target-libs — sourced function library (like msys-cross-common.sh).
#
# Source this from a PKGBUILD, then call:
#   copy_sysroot_pkg <sysroot> <pkgname> <pkgdir>
#
# msys-cross-gcc builds only the host compiler (make all-gcc); the TARGET runtime
# libraries (libgcc/crt, libstdc++, libgfortran, C++ headers, finclude .mod) come
# from the upstream MSYS2 gcc packages, which prepare-build-sysroot.sh installs
# into the build sysroot via pacman. pacman resolves the correct version/triple/
# layout for each target, so we just COPY the package's files out of the sysroot
# verbatim — no per-target URLs, sha256 pins, or layout relocation.
#
# Layout note: pacman installs everything under the sysroot subdir
# (<sysroot>/<subdir>/...), e.g. lib/gcc/<triple>/<ver>/, lib/lib{stdc++,...},
# include/c++/<ver>/. In an installed toolchain <target> is a SYMLINK to <subdir>
# (owned by msys-cross-filesystem), and the host driver searches
# "<prefix>/<target>/{lib,include}" → resolves to <subdir>. We pass the sysroot as
# <sysroot>/<subdir> (or the sysroot root for fortran, whose -Ql paths already
# carry the subdir), so files land in our pkgdir at the same <subdir>/... paths.

# copy_sysroot_pkg <sysroot> <pkgname> <pkgdir>
# Copies every regular file the named package installed in <sysroot> (per
# `pacman -Ql`) into <pkgdir>, preserving the relative path under the sysroot.
# Modes are preserved (cp -a); the caller's `find -name '*.exe' -delete` strips
# any Windows driver exes the upstream package carries in bin/.
copy_sysroot_pkg() {
    local sysroot="$1" pkgname="$2" pkgdir="$3"
    local conf="$sysroot/etc/pacman.d/pacman.conf" db="$sysroot/var/lib/pacman"
    local n=0 f rel

    # `pacman -Ql` prints "<pkgname> <absolute-path-under-sysroot>" per line.
    # Resolve the pacman root the same way -Ql reports paths: the DB/config live
    # at the sysroot ROOT, but the caller may pass <sysroot>/<subdir> as the path
    # to copy from. So locate the root by stripping a trailing subdir if present.
    local root="$sysroot"
    case "$sysroot" in
        */mingw64|*/mingw32|*/ucrt64|*/usr)
            root="$(dirname "$sysroot")"
            conf="$root/etc/pacman.d/pacman.conf"
            db="$root/var/lib/pacman"
            ;;
    esac

    while IFS= read -r f; do
        [ -f "$f" ] || continue                 # skip dirs
        case "$f" in */bin/*) continue ;; esac  # skip Windows driver exes/DLLs in bin/
        rel="${f#$root/}"                        # path relative to sysroot root
        mkdir -p "$pkgdir/$(dirname "$rel")"
        cp -a "$f" "$pkgdir/$rel"
        n=$((n + 1))
    done < <(pacman --root "$root" --config "$conf" --dbpath "$db" -Ql "$pkgname" \
             | awk '{print $2}')

    echo "copied $n files from $pkgname (sysroot $root) into pkgdir"
}
