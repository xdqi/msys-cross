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
# Per-target prefix so each ZIG_TARGET keeps its own arch's static .a (Linux x86_64
# and macOS arm64 deps coexist). DEPS still overrides explicitly if set.
_deps="${DEPS:-$_project_root/deps/install-${ZIG_TARGET:-x86_64-linux-gnu.2.11}}"

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

# AUR package source root (submodule under deps/<name>).
_aur_root="${AUR_PACKAGES:-$_project_root/deps}"

inherit_aur() {
    # $1 = AUR package dir name under deps/ (e.g. "pacman-static")
    local _aur_dir="$_aur_root/$1"
    local _aur_pkgbuild="$_aur_dir/PKGBUILD"

    # Source the raw AUR PKGBUILD. Sourcing runs its top-level body immediately
    # (which sets CC=musl-gcc and LDFLAGS=-static); callers MUST re-set CC/LDFLAGS
    # after the inherit_aur call to override them (build() reads ${CC}/${LDFLAGS}
    # at call time, so the later values win).
    source "$_aur_pkgbuild"

    # Drop Arch makedepends/pgp checks we don't honor in this repo.
    makedepends=()
    validpgpkeys=()
    for i in "${!sha512sums[@]}"; do sha512sums[$i]='SKIP'; done
    [ -n "${sha256sums+x}" ] && for i in "${!sha256sums[@]}"; do sha256sums[$i]='SKIP'; done

    # Local (non-URL) source entries become file:// against the AUR dir so makepkg
    # finds the vendored patches/keys.
    for i in "${!source[@]}"; do
        case "${source[$i]}" in
            *://*) ;;
            *) source[$i]="file://$_aur_dir/${source[$i]}" ;;
        esac
    done

    # Save the AUR functions for chaining/overriding (true-body fallback if absent).
    if declare -f prepare >/dev/null 2>&1; then
        eval "$(declare -f prepare | sed 's/^prepare /_aur_prepare /')"
    else
        _aur_prepare() { true; }
    fi
    if declare -f build >/dev/null 2>&1; then
        eval "$(declare -f build | sed 's/^build /_aur_build /')"
    else
        _aur_build() { true; }
    fi
    if declare -f package >/dev/null 2>&1; then
        eval "$(declare -f package | sed 's/^package /_aur_package /')"
    else
        _aur_package() { true; }
    fi
}

# Warning noise from building GCC's tree with zig cc (clang) is handled in the
# zigcc/zigc++ wrappers, which strip GCC's bare -Wall/-Wextra/-W/-Werror switches
# (clang-only diagnostics that don't apply to GCC's code). Nothing to do here.

setup_zig_env() {
    # $_zig_path is the build/zig symlink prepare-zig.sh points at the versioned
    # dir, so the version number lives in ONE place (prepare-zig.sh) — no need to
    # also list a version-specific path here.
    export PATH="$_install_prefix/bin:$_zig_path:$PATH"
    export CC="$_wrappers/zigcc"
    export CXX="$_wrappers/zigc++"
    export AR="zig ar"
    export RANLIB="zig ranlib"
    export CFLAGS="-O2 -I$_deps/include -fbracket-depth=512 -Wno-error"
    export CXXFLAGS="-O2 -I$_deps/include -fbracket-depth=512 -Wno-error"
    # Mach-O's ld has no -Bstatic/-Bdynamic. On a macOS target the deps prefix ships
    # only static .a (no .dylib), so a plain -L suffices to link them statically; on
    # Linux keep the GNU -Bstatic dance verbatim (byte-identical to before).
    case "${ZIG_TARGET:-}" in
        *macos*|*darwin*)
            export LDFLAGS="-L$_deps/lib" ;;
        *)
            export LDFLAGS="-L$_deps/lib -Wl,-Bstatic -lgmp -lmpfr -lmpc -lisl -lz -lzstd -Wl,-Bdynamic" ;;
    esac
}
