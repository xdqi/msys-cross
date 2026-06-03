#!/bin/bash
# Patch a zig install's bundled libc++ so C++17 aligned new/delete links for
# old glibc (<2.16) targets — no zig rebuild, no compat object, no -D flags.
#
# Usage: patch_zig_libcxx_oldglibc.sh <zig-install-dir>
#        patch_zig_libcxx_oldglibc.sh --zig-prefix <zig-install-dir>
#
# Applies pre-generated diffs from scripts/zig-patches/ with `patch -N`
# (idempotent: re-running is a no-op). Then self-verifies and, on failure,
# restores from patch's .orig backups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/zig-patches"

die() { echo "patch_zig_libcxx_oldglibc: $*" >&2; exit 1; }

# ---- arg parsing ----
case "${1:-}" in
    --zig-prefix) ZIG_PREFIX="${2:?--zig-prefix needs a dir}" ;;
    "")           die "usage: $0 <zig-install-dir>" ;;
    *)            ZIG_PREFIX="$1" ;;
esac
[ -d "$ZIG_PREFIX" ] || die "not a directory: $ZIG_PREFIX"

ZIG_BIN="$ZIG_PREFIX/zig"
[ -x "$ZIG_BIN" ] || die "no zig binary at $ZIG_BIN"

LIBCXX="$ZIG_PREFIX/lib/libcxx"
[ -f "$LIBCXX/include/__config" ] || die "no libc++ __config under $LIBCXX"

# ---- era detection ----
if [ -f "$LIBCXX/src/include/aligned_alloc.h" ]; then
    ERA="0.17-dev"
    PATCHES=(config-0.17-dev.patch aligned_alloc-0.17-dev.patch)
else
    ERA="0.16.0"
    PATCHES=(config-0.16.0.patch)
fi
echo "patch_zig_libcxx_oldglibc: era=$ERA prefix=$ZIG_PREFIX"

# ---- apply ----
apply_one() {
    local pf="$PATCH_DIR/$1" out rc
    [ -f "$pf" ] || die "missing patch file: $pf"
    out="$(patch -N -p1 --fuzz=3 -d "$LIBCXX" < "$pf" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "patch_zig_libcxx_oldglibc: applied $1"
    elif printf '%s\n' "$out" | grep -qiE 'previously applied|Reversed'; then
        echo "patch_zig_libcxx_oldglibc: $1 already applied (skipping)"
    else
        printf '%s\n' "$out" >&2
        die "failed to apply $1 (see .rej under $LIBCXX)"
    fi
}
for p in "${PATCHES[@]}"; do apply_one "$p"; done

# (Task 3 appends self-verify below.)
