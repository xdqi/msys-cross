#!/bin/bash
# Provision the arm64-macOS static deps (gmp, mpfr, mpc, isl, zlib, zstd) by STEALING the
# prebuilt static libs + headers from Homebrew's arm64 bottles, instead of cross-compiling
# them with zig. Cross-building these (esp. gmp/mpfr/mpc/isl) on the zig macOS SDK is fiddly
# (asm/configure host probes); Homebrew already ships correct arm64 Mach-O .a, so this is
# both faster and more reliable. Output matches build_deps.sh's contract:
#   $DEPS_INSTALL/lib/lib{gmp,mpfr,mpc,isl,z,zstd}.a + include/ + lib/pkgconfig/*.pc
#   + lib*.so -> lib*.a symlinks (for zig's no_fallback linker)
# so the GCC PKGBUILDs' --with-gmp=$_deps etc. and pacman's pkg-config all just work.
#
# Bottles come from ghcr.io (Homebrew's registry) via an anonymous token; versions are
# resolved from formulae.brew.sh so they track Homebrew. NOT pinned to a macOS release of
# the toolchain itself — these are arch-independent-ABI static libs; we take the oldest
# arm64 bottle common to all (arm64_sonoma) so the .a load commands' minos stays low.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Guard: the per-target cross env (ZIG_TARGET) must have been sourced from
# scripts/env-darwin.sh first (build-darwin.sh does this). This script does NOT source
# msys-cross-common.sh, so it carries its own copy of the marker guard.
[ "${MSYS_CROSS_ENV_LOADED:-}" = 1 ] || {
    echo "ERROR: source scripts/env-darwin.sh (or build via build-darwin.sh) first" >&2
    exit 1
}

PREFIX="${DEPS_INSTALL:-$PROJECT_ROOT/deps/install-$ZIG_TARGET}"
BREW_ARCH_TAG="${BREW_ARCH_TAG:-arm64_sonoma}"   # oldest arm64 bottle common to these formulae
ZIGBIN="$(readlink -f "${ZIG_PATH:-$PROJECT_ROOT/build/zig}" 2>/dev/null || true)"

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"
_tmp="$PREFIX/.brewtmp"; rm -rf "$_tmp"; mkdir -p "$_tmp"

# formula -> the static lib basename it must yield (sanity check). isl/zstd ship extra .a;
# we copy ALL .a from each bottle's lib/.
declare -A WANT_LIB=( [gmp]=libgmp.a [mpfr]=libmpfr.a [libmpc]=libmpc.a [isl]=libisl.a [zlib]=libz.a [zstd]=libzstd.a )

# Retry transient network/CDN blips: these public APIs (formulae.brew.sh, ghcr token)
# occasionally return an empty body, which would otherwise crash json.load with
# "Expecting value: line 1 column 1". --retry-all-errors retries on HTTP errors too.
_curl_api() { curl -fsS --connect-timeout 20 --retry 4 --retry-all-errors --retry-delay 2 "$@"; }

ghcr_token() {
    _curl_api "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/$1:pull" \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])"
}

echo "=== Stealing arm64 static deps from Homebrew bottles ($BREW_ARCH_TAG) → $PREFIX ==="
for f in gmp mpfr libmpc isl zlib zstd; do
    _json=$(_curl_api "https://formulae.brew.sh/api/formula/$f.json")
    [ -n "$_json" ] || { echo "ERROR: empty JSON for formula $f (network?)" >&2; exit 1; }
    url=$(printf '%s' "$_json" \
          | python3 -c "import sys,json;print(json.load(sys.stdin)['bottle']['stable']['files']['$BREW_ARCH_TAG']['url'])")
    tok=$(ghcr_token "$f")
    curl -fsSL --connect-timeout 30 --retry 3 \
        -H "Authorization: Bearer $tok" \
        -H "Accept: application/vnd.oci.image.layer.v1.tar+gzip" \
        "$url" -o "$_tmp/$f.tar.gz"
    bsdtar xf "$_tmp/$f.tar.gz" -C "$_tmp"
    # bottle layout: <formula>/<ver>/{lib,include}
    d=$(find "$_tmp/$f" -maxdepth 1 -mindepth 1 -type d | head -1)
    cp -a "$d/lib/"*.a "$PREFIX/lib/" 2>/dev/null || true
    [ -d "$d/lib/pkgconfig" ] && cp -a "$d/lib/pkgconfig/"*.pc "$PREFIX/lib/pkgconfig/" 2>/dev/null || true
    cp -a "$d/include/." "$PREFIX/include/" 2>/dev/null || true
    [ -e "$PREFIX/lib/${WANT_LIB[$f]}" ] || { echo "ERROR: $f bottle yielded no ${WANT_LIB[$f]}" >&2; exit 1; }
    echo "  + $f $(basename "$d")  (${WANT_LIB[$f]})"
done
rm -rf "$_tmp"

# Relocate Homebrew placeholders in the stolen .pc files. Bottles ship pkg-config files with
# un-substituted @@HOMEBREW_PREFIX@@/opt/<formula> and @@HOMEBREW_CELLAR@@/<formula>/<ver>
# tokens (brew rewrites them at `brew install`; we took the raw bottle). Left as-is, a
# consumer's `pkg-config --libs zlib` yields -L@@HOMEBREW_PREFIX@@/opt/zlib/lib and libtool
# dies ("cannot determine absolute directory name"). Our layout is FLAT — all libs in
# $PREFIX/lib, all headers in $PREFIX/include — so collapse every "<placeholder>/.../<opt-or-
# cellar-version segment>" down to $PREFIX, after which ${prefix}/lib and ${prefix}/include
# (and any inline -L/-I) resolve correctly. Matches both placeholder forms:
#   @@HOMEBREW_PREFIX@@/opt/<formula>          -> $PREFIX
#   @@HOMEBREW_CELLAR@@/<formula>/<version>    -> $PREFIX
# Use | as the sed delimiter: the patterns START with @, so an @ delimiter would be
# misparsed; | appears in neither the placeholders nor any filesystem path.
_pfx_esc=$(printf '%s' "$PREFIX" | sed 's/[&|\]/\\&/g')
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
    [ -e "$pc" ] || continue
    sed -i \
        -e "s|@@HOMEBREW_PREFIX@@/opt/[A-Za-z0-9._+-]*|$_pfx_esc|g" \
        -e "s|@@HOMEBREW_CELLAR@@/[A-Za-z0-9._+-]*/[A-Za-z0-9._+-]*|$_pfx_esc|g" \
        "$pc"
done
# Fail loudly if any placeholder survived (a new bottle format / unforeseen token).
if grep -rq '@@HOMEBREW' "$PREFIX/lib/pkgconfig/" 2>/dev/null; then
    echo "ERROR: unrelocated @@HOMEBREW...@@ placeholder remains in a stolen .pc:" >&2
    grep -rn '@@HOMEBREW' "$PREFIX/lib/pkgconfig/" >&2
    exit 1
fi

# .so -> .a symlinks so zig's no_fallback linker resolves -lgmp etc. (same as build_deps.sh).
for lib in gmp mpfr mpc isl z zstd; do
    ln -sf "lib${lib}.a" "$PREFIX/lib/lib${lib}.so"
done

# Verify arch (must be arm64 Mach-O, not Intel/ELF).
echo "=== Verify arm64 Mach-O ==="
for lib in gmp mpfr mpc isl z zstd; do
    _o=$(mktemp -d)
    ( cd "$_o" && ar x "$PREFIX/lib/lib${lib}.a" 2>/dev/null
      o=$(ls *.o 2>/dev/null | head -1)
      printf '  lib%-6s %s\n' "$lib.a" "$([ -n "$o" ] && file -b "$o" | cut -d, -f1 || echo '(empty)')" )
    rm -rf "$_o"
done
echo "=== darwin deps ready: $PREFIX ==="
ls -la "$PREFIX/lib/lib"{gmp,mpfr,mpc,isl,z,zstd}.a
