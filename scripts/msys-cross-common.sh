# msys-cross-common.sh — shared helpers for msys2-cross build PKGBUILDs
#
# All paths are relative to the project root or overridable via environment:
#   BOOTSTRAP_PREFIX  — MSYS2 sysroot (headers, libs, binutils)
#   ZIG_PATH          — Zig compiler installation
#   DEPS              — static build deps (gmp, mpfr, mpc, isl, zlib, zstd)
#
# Usage: source this file, then call inherit_msys2 <msys2-pkg-dir>
# This sources the raw MSYS2 PKGBUILD, then lets the caller override
# metadata (pkgname, depends) and fix functions via sed.

_wrappers="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_project_root="$(cd "$_wrappers/.." && pwd)"

# MSYS2 PKGBUILD sources (submodule / vendored)
_msys2_root="${MSYS2_PACKAGES:-$_project_root/deps/MSYS2-packages}"

# Bootstrap prefix: MSYS2 sysroot with target headers/libs/binutils.
# The bootstrap is prepared by scripts/build.sh (or manually) under build/bootstrap-prefix/.
_bootstrap_prefix="${BOOTSTRAP_PREFIX:-$_project_root/build/bootstrap-prefix}"

# Static build dependencies (gmp, mpfr, mpc, isl, zlib, zstd) from build_deps.sh.
_deps="${DEPS:-$_project_root/deps/install}"

# Install prefix: where built cross packages live during the build (binutils, GCC).
# GCC build needs cross-as/ld in PATH from here.
_install_prefix="${INSTALL_PREFIX:-$_project_root/build/install-prefix}"

# Zig compiler toolchain.  Default: build/zig (created by prepare-zig.sh).
_zig_path="${ZIG_PATH:-$_project_root/build/zig}"

inherit_msys2() {
    # $1 = MSYS2 package dir name (e.g. "mingw-w64-cross-gcc")
    local _msys2_dir="$_msys2_root/$1"
    local _msys2_pkgbuild="$_msys2_dir/PKGBUILD"

    # --- grep: version metadata (so we can override pkgrel cleanly) ---
    pkgver=$(grep '^pkgver=' "$_msys2_pkgbuild" | head -1 | cut -d= -f2)
    _realname=$(grep '^_realname=' "$_msys2_pkgbuild" | head -1 | cut -d= -f2)
    _msys2_pkgrel=$(grep '^pkgrel=' "$_msys2_pkgbuild" | head -1 | cut -d= -f2)

    # --- source raw MSYS2 PKGBUILD (no sed — each PKGBUILD fixes what it needs) ---
    source "$_msys2_pkgbuild"

    # --- override: delete what we don't want ---
    makedepends=()
    validpgpkeys=()

    # Skip all sha256sum checks — MSYS2 patches in the submodule may be
    # modified/rebased between checkouts, making checksums mismatch.
    for i in "${!sha256sums[@]}"; do
        sha256sums[$i]='SKIP'
    done

    # --- fix source[]: relative patches → file:// (makepkg ignores bare abs paths) ---
    for i in "${!source[@]}"; do
        case "${source[$i]}" in
            *://*) ;;
            *) source[$i]="file://$_msys2_dir/${source[$i]}" ;;
        esac
    done

    # --- save original functions for later chaining ---
    eval "$(declare -f prepare 2>/dev/null | sed 's/^prepare /_msys2_prepare /' || echo '_msys2_prepare() { true; }')"
    eval "$(declare -f build 2>/dev/null | sed 's/^build /_msys2_build /' || echo '_msys2_build() { true; }')"
}

# Warning noise from building GCC's tree with zig cc (clang) is handled in the
# zigcc/zigc++ wrappers, which strip GCC's bare -Wall/-Wextra/-W/-Werror switches
# (clang-only diagnostics that don't apply to GCC's code). Nothing to do here.

setup_zig_env() {
    export PATH="$_install_prefix/bin:$_zig_path:$_zig_path-x86_64-linux-0.16.0:$PATH"
    export CC="$_wrappers/zigcc"
    export CXX="$_wrappers/zigc++"
    export AR="zig ar"
    export RANLIB="zig ranlib"
    export CFLAGS="-O2 -I$_deps/include -fbracket-depth=512 -Wno-error"
    export CXXFLAGS="-O2 -I$_deps/include -fbracket-depth=512 -Wno-error"
    export LDFLAGS="-L$_deps/lib -Wl,-Bstatic -lgmp -lmpfr -lmpc -lisl -lz -lzstd -Wl,-Bdynamic"
}
