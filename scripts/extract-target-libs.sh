# msys-cross extract-target-libs — sourced function library (like msys-cross-common.sh).
#
# Source this from a PKGBUILD, then call:
#   extract_target_libs <upstream-pkg.tar.zst> <target-triple> <ver> \
#                        <pkgdir> <stage_prefix> <sysroot-subdir> \
#                        [<extra-pkg.tar.zst>]
#
# Extracts the gcc-internal target runtime libs from upstream MSYS2 gcc binary
# packages and relocates them into a cross-gcc install. The host compiler built
# with --disable-version-specific-runtime-libs searches the standard cross paths,
# so the upstream bits drop straight in.
#
# Layout note (verified via -print-file-name):
#   * gcc-internal bits (crt*.o, libgcc*.a, finclude) live at the package ROOT
#     under  lib/gcc/<target>/<ver>/  — the cross-gcc package owns this path.
#   * the runtime libs/headers (libstdc++, libgfortran, libquadmath, C++ headers)
#     must go under the MSYS2 SYSROOT SUBDIR (<subdir> = mingw64/mingw32/ucrt64/usr),
#     NOT the literal <target> triple dir. The cross-gcc searches
#     "<prefix>/<target>/{lib,include}", but in an installed toolchain <target>
#     is a SYMLINK to <subdir> owned by the msys-cross-filesystem package. Writing
#     a real <target>/ dir here would conflict with that symlink at install time,
#     so we write into <subdir>/ and let the symlink resolve the search path to it.

extract_target_libs() {
    local pkg="$1" target="$2" ver="$3" pkgdir="$4" sp="$5" subdir="$6" fpkg="${7:-}"
    local tmp; tmp="$(mktemp -d)"

    bsdtar -xf "$pkg" -C "$tmp"
    [ -n "$fpkg" ] && bsdtar -xf "$fpkg" -C "$tmp"

    # Pick whichever upstream root dir is present. A bare `ls -d a b c` exits
    # non-zero when some names are missing, which under `set -euo pipefail` would
    # abort the caller — so probe each candidate explicitly instead.
    local up="" c
    for c in mingw64 mingw32 ucrt64 usr; do
        if [ -d "$tmp/$c" ]; then up="$c"; break; fi
    done
    if [ -z "$up" ]; then
        echo "ERROR: no upstream root dir (mingw64/mingw32/ucrt64/usr) in $pkg" >&2
        rm -rf "$tmp"; return 1
    fi
    local src="$tmp/$up"

    # gcc-internal version-specific bits → package root lib/gcc/<target>/<ver>/
    local dst_gcc="$pkgdir$sp/lib/gcc/$target/$ver"; mkdir -p "$dst_gcc"
    cp -a "$src/lib/gcc/$target/$ver/." "$dst_gcc/"

    # runtime libs (libstdc++, libgfortran, libquadmath, ...) → <subdir>/lib/
    local dst_lib="$pkgdir$sp/$subdir/lib"; mkdir -p "$dst_lib"
    cp -a "$src/lib/." "$dst_lib/" 2>/dev/null || true

    # C++ headers → <subdir>/include/c++/
    if [ -d "$src/include/c++" ]; then
        mkdir -p "$pkgdir$sp/$subdir/include/c++"
        cp -a "$src/include/c++/." "$pkgdir$sp/$subdir/include/c++/"
    fi

    # NOTE: deliberately NO DLL sweep here. We only extract link-time artifacts
    # (.a, .dll.a import libs, .spec, .o crt, C++/Fortran headers — all covered by
    # the cp -a of $src/lib above). Runtime DLLs (libstdc++-6.dll, libgfortran-5.dll,
    # libgcc_s_seh-1.dll, ...) are provided by the sysroot mingw-w64-*-gcc-libs
    # dependency, not by us. A blanket `find -name lib*.dll` here would also wrongly
    # sweep the HOST liblto_plugin.dll into the target bin dir.
    echo "extracted target libs for $target ($subdir) from $(basename "$pkg")"
    rm -rf "$tmp"
}
