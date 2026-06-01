# Shared helpers for the zigcc / zigc++ wrappers — SOURCED, never exec'd.
#
# This is deliberately a sourced library, not an executable driver: the wrappers
# `source` it so $0 stays the wrapper itself (a real clang-like cc/c++). sccache
# probes the wrapped compiler and reconstructs the compile from $0; an exec'd
# `bash driver.sh <sub>` layer makes $0 the driver, which broke sccache's probe and
# dropped the C++ language selection (libc++ "is_trivially_destructible not
# implemented" / integer-pack errors when building GCC's .c-as-C++ units). Sourcing
# keeps the dedup without that indirection.

# The zig compilation target. Defaults to the canonical Linux glibc target; override
# via the ZIG_TARGET env var to retarget the whole toolchain (e.g. aarch64-macos.11.0
# for a macOS-hosted cross build). Both wrappers pass this verbatim to `zig cc/c++
# -target`, and zig_sccache_reexec folds it into the sccache cache-buster (below).
ZIG_CC_TARGET="${ZIG_TARGET:-x86_64-linux-gnu.2.11}"

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
            # sccache hashes the "compiler" via $0 = THIS wrapper script, whose bytes
            # don't change when the real zig is upgraded, and it never sees the -target
            # we inject internally. So two distinct compiles (different zig version, or
            # different ZIG_TARGET) can collide on one cache key. Fold both into
            # SCCACHE_C_CUSTOM_CACHE_BUSTER (a whitelisted CACHED_ENV_VAR, purpose-built
            # for this) so the key is partitioned by real zig version AND target.
            export SCCACHE_C_CUSTOM_CACHE_BUSTER="$(zig version 2>/dev/null):$ZIG_CC_TARGET"
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
# Also drops legacy Mach-O libtool linker flags zig's ld rejects (-single_module,
# -bind_at_load) — autoconf/libtool emit these on a darwin host (e.g. isl's test progs)
# and they're harmless to omit. These tokens never appear on a Linux build, so the
# Linux path is unaffected.
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
            -single_module|-bind_at_load) continue ;;
        esac
        ZIG_ARGS+=("$a")
    done
}
