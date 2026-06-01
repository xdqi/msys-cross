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

# _place_internal_libs <src-triple> <subdir> [<dst-triple>]
# Put the gcc-internal version dir where OUR host driver looks for link artifacts.
# copy_sysroot_pkg drops the upstream gcc package verbatim under the sysroot subdir,
# so the gcc-internal version dir lands at <subdir>/lib/gcc/<src-triple>/<ver>/ (that
# is where native MSYS2's in-sysroot driver finds it). OUR host driver lives in the
# package-root bin/ — one level ABOVE <subdir>/ — so its FIRST library search dir is
# the package-root lib/gcc/<dst-triple>/<ver>/ (it never goes through the <triple> ->
# <subdir> symlink to reach the internal libs). That dir only holds the headers/
# plugin our DESTDIR install put there, so -lgcc/-lgcc_eh/crt*.o fail to link.
# Merge the upstream internal-dir's LINK artifacts (libgcc*.a, libgcov.a, crt*.o,
# finclude/, etc.) into the package-root version dir. Skip Windows host-target
# binaries (cc1/lto1/... .exe and liblto_plugin.dll*) — our package supplies the
# host backends under libexec/; those upstream PE blobs would just bloat the package.
#   src-triple = the triple the upstream package used under <subdir>/lib/gcc/
#   subdir     = sysroot subdir copy_sysroot_pkg wrote into (mingw64/mingw32/ucrt64/usr)
#   dst-triple = the triple OUR host driver searches (defaults to src-triple).
#                ucrt64 differs: upstream uses the PLAIN triple x86_64-w64-mingw32,
#                but our ucrt driver searches lib/gcc/x86_64-w64-mingw32ucrt/.
_place_internal_libs() {
    local target=$1 subdir=$2 dsttriple="${3:-$1}"
    local src="$pkgdir/$subdir/lib/gcc/$target/$pkgver"
    local dst="$pkgdir/lib/gcc/$dsttriple/$pkgver"
    [ -d "$src" ] || { echo "WARNING: no upstream internal dir at $src" >&2; return 0; }
    mkdir -p "$dst"
    cp -a "$src/." "$dst/"
    # The internal dir's only Windows binaries are *.exe backends and the LTO plugin
    # DLL; drop them from the package-root copy (host backends come from libexec/).
    find "$dst" \( -name '*.exe' -o -name 'liblto_plugin.dll' -o -name 'liblto_plugin.dll.a' \
                   -o -name 'msys-lto_plugin.dll' -o -name 'g++-mapper-server.exe' \) -delete
}

