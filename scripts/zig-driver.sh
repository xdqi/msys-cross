#!/bin/bash
# Shared implementation for the zigcc / zigc++ compiler wrappers.
#
# Usage (from the wrappers):
#   #!/bin/bash
#   exec bash "$(dirname "$0")/zig-driver.sh" cc  "$@"     # zigcc
#   exec bash "$(dirname "$0")/zig-driver.sh" c++ "$@"     # zigc++
#
# $1 is the zig subcommand (cc | c++); the rest are the compiler args.
#
# Responsibilities (identical for C and C++):
#  - Route through sccache when available (two-role trick: sccache can't wrap the
#    two-token `zig cc` directly, so we re-exec as `sccache <self>` under a guard
#    so sccache probes a single-exec clang it can cache). Prefer $SCCACHE_PATH
#    (exported by mozilla-actions/sccache-action) since runuser may reset PATH.
#  - Quiet the clang-only warning noise from building GCC's own tree:
#      (1) strip GCC's bare developer switches -Wall/-Wextra/-W/-Werror (they turn
#          on diagnostics like -Wmismatched-tags that don't apply to GCC's code),
#          plus the GCC-only warning flags clang doesn't understand at all
#          (-Wconditionally-supported, -Wshadow=local — these would otherwise each
#          emit an "unknown warning option" warning). Functional -Werror=narrowing
#          / -Wno-error=narrowing are preserved (exact match).
#      (2) append explicit -Wno-* LAST (so they win) for diagnostics clang enables
#          by DEFAULT, which survive the -Wall drop. (No -Wno-unknown-warning-option
#          needed: every flag we pass is recognised, and the GCC-only ones are
#          filtered out above rather than tolerated.)
#  - For c++ compile invocations (-c/-E/-S), add `-x c++`.
set -u

_zig_sub="$1"; shift

# sccache routing (see above). _ZIGCC_INNER guards against infinite recursion:
# the outer call re-execs `sccache <self> ...`; sccache then re-runs <self> with
# the guard set, which falls through to the real compile below.
if [ -z "${_ZIGCC_INNER:-}" ]; then
    _sccache="${SCCACHE_PATH:-}"
    [ -z "$_sccache" ] && _sccache="$(command -v sccache 2>/dev/null || true)"
    if [ -n "$_sccache" ]; then
        _ZIGCC_INNER=1 exec "$_sccache" "$0" "$_zig_sub" "$@"
    fi
fi
unset _ZIGCC_INNER 2>/dev/null || true

ZIG_WNO=(
    -Wno-nontrivial-memcall -Wno-ignored-attributes
    -Wno-gnu-zero-variadic-macro-arguments -Wno-constant-logical-operand
    -Wno-shift-count-overflow -Wno-tautological-compare
    -Wno-parentheses-equality -Wno-nested-anon-types -Wno-string-plus-int
    -Wno-deprecated-declarations -Wno-c23-extensions
)

is_compile=false
args=()
for a in "$@"; do
    case "$a" in
        -c|-E|-S) is_compile=true ;;
        # GCC developer switches that flood the log with clang-only diagnostics:
        -Wall|-Wextra|-W|-Werror) continue ;;
        # GCC-only warning flags clang can't parse (would each warn "unknown option"):
        -Wconditionally-supported|-Wshadow=local) continue ;;
    esac
    args+=("$a")
done

# c++ compile units need -x c++ (mirrors the historic zigc++ behaviour).
xflag=()
if [ "$_zig_sub" = "c++" ] && $is_compile; then
    xflag=(-x c++)
fi

exec zig "$_zig_sub" "${xflag[@]}" -target x86_64-linux-gnu.2.11 "${args[@]}" "${ZIG_WNO[@]}"
