# The full body of the zigcc / zigc++ wrappers — SOURCED, never exec'd. Each wrapper is
# just a shebang + `source .../zig-common.sh <mode> "$@"`, where <mode> is the literal
# `cc` or `c++` token that is this file's only point of variation; everything else lives
# here and is driven by zig_main (below).
#
# It is deliberately sourced, not run as `bash driver.sh <sub>`: sourcing keeps $0 as the
# wrapper itself (a real clang-like cc/c++), which is what sccache probes and reconstructs
# the compile from. An exec'd driver layer makes $0 the driver, which broke sccache's probe
# and dropped the C++ language selection (libc++ "is_trivially_destructible not implemented"
# / integer-pack errors when building GCC's .c-as-C++ units).
#
# It is NOT a symlink target either: a symlink would hand sccache identical bytes for the cc
# and c++ roles, collide their cache keys, and reintroduce the same C++-selection bug.

# The zig compilation target. Defaults to the canonical Linux glibc target; override
# via the ZIG_TARGET env var to retarget the whole toolchain (e.g. aarch64-macos.11.0
# for a macOS-hosted cross build). Both wrappers pass this verbatim to `zig cc/c++
# -target`, and zig_sccache_reexec folds it into the sccache cache-buster (below).
#
# Special value ZIG_TARGET=native: build for the BUILD machine (the Linux runner), mapped to
# that host's canonical gnu target. Used by LLVM's NATIVE cross sub-build — on a darwin host
# build the main toolchain targets aarch64-macos, but the NATIVE tablegens must run on the
# Linux builder, so they need a build-native compiler. zig cc is still clang underneath, so
# the inherited clang-only CFLAGS (-fbracket-depth=512) are accepted; only the target changes.
# Mapping to a fixed triple (not zig's bare `native`) keeps -dumpmachine and the sccache
# cache-buster deterministic. These NATIVE tools aren't shipped, so the 2.11 glibc floor is
# irrelevant — it just reuses the linux target.
ZIG_CC_TARGET="${ZIG_TARGET:-x86_64-linux-gnu.2.11}"
if [ "$ZIG_CC_TARGET" = native ]; then
    case "$(uname -m)" in
        x86_64)         ZIG_CC_TARGET="x86_64-linux-gnu.2.11" ;;
        aarch64|arm64)  ZIG_CC_TARGET="aarch64-linux-gnu.2.11" ;;
        *)              ZIG_CC_TARGET="$(uname -m)-linux-gnu" ;;
    esac
fi

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

# zig_handle_dumpmachine "$@"
# GNU gcc's `-dumpmachine` prints the bare target triple and exits 0; build systems
# (meson — meson.build:273 detect_machine_info) run it to learn the target. Our
# wrappers drive `zig cc -target $ZIG_CC_TARGET`, and `zig cc -dumpmachine` echoes that
# target (e.g. `x86_64-unknown-linux-gnu.2.11`) but THEN re-parses its own target string,
# rejects the glibc/OS-version field with
#   zig: error: version '.2.11' in target triple '…' is invalid
# and exits 1 — so meson aborts. A normal GNU machine triple carries no version suffix,
# so emulate gcc: print a clean GNU-style triple derived from ZIG_CC_TARGET and exit 0
# before handing off to zig. Call FIRST in the wrapper (it may exit). The triple must
# track the actual target so a non-default ZIG_TARGET (e.g. a macOS host) reports right.
zig_handle_dumpmachine() {
    local a
    for a in "$@"; do
        [ "$a" = "-dumpmachine" ] || continue
        # Map ZIG_CC_TARGET -> GNU-style machine triple (strip the version suffix; use
        # the vendor/os spelling GNU toolchains expect).
        case "${ZIG_CC_TARGET}" in
            *macos*)   echo "${ZIG_CC_TARGET%%-*}-apple-darwin20" ;;   # aarch64-macos.11.0 -> aarch64-apple-darwin20
            x86_64-linux-gnu*)  echo "x86_64-unknown-linux-gnu" ;;
            aarch64-linux-gnu*) echo "aarch64-unknown-linux-gnu" ;;
            *) echo "${ZIG_CC_TARGET%%.*}" ;;                          # generic: drop any .version
        esac
        exit 0
    done
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

# zig_main cc|c++ "$@"
# The whole wrapper body, so zigcc / zigc++ are each just a shebang + one `source` of
# this file, differing only in the mode token (cc / c++) they pass as the first arg:
#   source .../zig-common.sh cc  "$@"      # zigcc
#   source .../zig-common.sh c++ "$@"      # zigc++
# (No symlink — a symlink would feed identical bytes to sccache for both roles and
# collide their cache keys; two tiny wrappers passing different modes is the point.)
# Sourcing keeps $0 as the wrapper itself, which is what sccache probes and what
# zig_sccache_reexec re-execs as `sccache "$0" …`; the mode rides through that round-trip
# as a normal positional arg, so the inner role still drives the right compiler.
# c++ mode adds an explicit `-x c++` on compile invocations so a .c source
# (libgcc/libgcov-util.c etc.) engages libc++'s C++ frontend — see zigc++ history for the
# <type_traits> errors otherwise.
zig_main() {
    local mode="$1"; shift   # cc | c++ ; the rest of "$@" is the real compiler command line
    case "$mode" in
        cc|c++) ;;
        *) echo "zig-common.sh: bad mode '$mode' (expected cc or c++)" >&2; exit 2 ;;
    esac

    zig_handle_dumpmachine "$@"    # gcc-compatible -dumpmachine (exits 0)
    zig_sccache_reexec "$@"        # outer role re-execs under sccache; inner falls through
    zig_filter_args "$@"           # sets ZIG_ARGS (filtered), ZIG_IS_COMPILE

    local xflag=()
    [ "$mode" = c++ ] && $ZIG_IS_COMPILE && xflag=(-x c++)
    exec zig "$mode" "${xflag[@]}" -target "$ZIG_CC_TARGET" "${ZIG_ARGS[@]}" "${ZIG_WNO[@]}"
}

zig_main "$@"
