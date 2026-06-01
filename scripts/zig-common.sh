# Shared helpers for the zigcc / zigc++ wrappers — SOURCED, never exec'd.
#
# This is deliberately a sourced library, not an executable driver: the wrappers
# `source` it so $0 stays the wrapper itself (a real clang-like cc/c++). sccache
# probes the wrapped compiler and reconstructs the compile from $0; an exec'd
# `bash driver.sh <sub>` layer makes $0 the driver, which broke sccache's probe and
# dropped the C++ language selection (libc++ "is_trivially_destructible not
# implemented" / integer-pack errors when building GCC's .c-as-C++ units). Sourcing
# keeps the dedup without that indirection.

# zig_sccache_reexec "$@"
# sccache two-role trick: sccache can't wrap the two-token `zig cc` directly, so the
# wrapper re-execs as `sccache <self> "$@"` (outer role) and sccache then re-runs
# <self> with _ZIGCC_INNER set (inner role) which falls through to the real compile.
# Call this FIRST in the wrapper, before any arg munging, passing the original "$@".
# Prefer $SCCACHE_PATH (mozilla-actions/sccache-action) since PATH may be reset when
# the build drops to an unprivileged user via runuser; else sccache on PATH; else
# no-op (caching is opt-in — local builds without sccache compile directly).
zig_sccache_reexec() {
    if [ -z "${_ZIGCC_INNER:-}" ]; then
        local _sccache="${SCCACHE_PATH:-}"
        [ -z "$_sccache" ] && _sccache="$(command -v sccache 2>/dev/null || true)"
        if [ -n "$_sccache" ]; then
            _ZIGCC_INNER=1 exec "$_sccache" "$0" "$@"
        fi
    fi
    unset _ZIGCC_INNER 2>/dev/null || true
}

# -Wno-* for clang diagnostics that are ON BY DEFAULT (survive the -Wall drop) and
# only add noise when building GCC's tree. Appended LAST by the wrappers so they win.
ZIG_WNO=(
    -Wno-nontrivial-memcall -Wno-ignored-attributes
    -Wno-gnu-zero-variadic-macro-arguments -Wno-constant-logical-operand
    -Wno-shift-count-overflow -Wno-tautological-compare
    -Wno-parentheses-equality -Wno-nested-anon-types -Wno-string-plus-int
    -Wno-deprecated-declarations -Wno-c23-extensions
)

# zig_filter_args "$@"
# Strip GCC's bare developer warning switches (-Wall/-Wextra/-W/-Werror — clang-only
# diagnostics that don't apply to GCC's code) and the GCC-only warning flags clang
# can't parse (-Wconditionally-supported, -Wshadow=local — each would warn "unknown
# warning option"). Functional -Werror=narrowing / -Wno-error=* forms are exact-match
# and preserved. Also detect a compile invocation (-c/-E/-S).
# Outputs: ZIG_ARGS=(filtered args), ZIG_IS_COMPILE=true|false.
zig_filter_args() {
    ZIG_ARGS=()
    ZIG_IS_COMPILE=false
    local a
    for a in "$@"; do
        case "$a" in
            -c|-E|-S) ZIG_IS_COMPILE=true ;;
            -Wall|-Wextra|-W|-Werror) continue ;;
            -Wconditionally-supported|-Wshadow=local) continue ;;
        esac
        ZIG_ARGS+=("$a")
    done
}
