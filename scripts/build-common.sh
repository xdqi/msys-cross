# Shared helpers for the build entrypoints (scripts/build.sh = linux x86_64,
# scripts/build-darwin.sh = arm64 macOS host). SOURCED, not executed.
#
# Caller must have already set: SCRIPTS_DIR, PROJECT_ROOT, and the path exports
# (PKGDEST/SRCDEST/LOGDEST/DEPS/DEPS_INSTALL/BOOTSTRAP_PREFIX/INSTALL_PREFIX/
# ZIG_PATH/DEPS_CACHE/JOBS) — both entrypoints export these before sourcing, with
# their own values (the darwin entrypoint points PKGDEST/DEPS at darwin-specific
# dirs). Optional: _MSYS_CROSS_MAKEPKG_CONFIG names a makepkg --config file forwarded
# to every makepkg invocation (the darwin pass uses makepkg-darwin-arm64.conf; the
# linux pass leaves it unset → unchanged behavior).

# The whole build runs as one unprivileged user (so the sccache server is single-uid
# and never hands another uid root-owned objects). runuser scrubs the environment, so
# forward the bits the build/sccache need explicitly via `env`. Anything writable is
# chown'd to builduser before use.
run_as_builduser() {
    chown -R builduser:builduser "$PROJECT_ROOT/build" "$PKGDEST" "$SRCDEST" "$LOGDEST" 2>/dev/null || true
    runuser -u builduser -- env \
        PATH="$PATH" \
        ZIG_PATH="$ZIG_PATH" \
        DEPS="$DEPS" DEPS_INSTALL="$DEPS_INSTALL" DEPS_CACHE="$DEPS_CACHE" \
        BOOTSTRAP_PREFIX="$BOOTSTRAP_PREFIX" INSTALL_PREFIX="$INSTALL_PREFIX" \
        PKGDEST="$PKGDEST" SRCDEST="$SRCDEST" LOGDEST="$LOGDEST" \
        ${BUILDDIR:+BUILDDIR="$BUILDDIR"} \
        ${_MSYS_CROSS_TARGET:+_MSYS_CROSS_TARGET="$_MSYS_CROSS_TARGET"} \
        ${ZIG_TARGET:+ZIG_TARGET="$ZIG_TARGET"} \
        ${_MSYS_CROSS_HOST:+_MSYS_CROSS_HOST="$_MSYS_CROSS_HOST"} \
        ${_MSYS_CROSS_BUILD:+_MSYS_CROSS_BUILD="$_MSYS_CROSS_BUILD"} \
        ${_MSYS_CROSS_DUMPSPECS:+_MSYS_CROSS_DUMPSPECS="$_MSYS_CROSS_DUMPSPECS"} \
        ${_MSYS_CROSS_ZLIB+_MSYS_CROSS_ZLIB="$_MSYS_CROSS_ZLIB"} \
        JOBS="$JOBS" \
        SCCACHE_PATH="${SCCACHE_PATH:-}" \
        SCCACHE_DIR="${SCCACHE_DIR:-}" \
        SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-}" \
        "$@"
}

# build_pkg <pkg-dir> [makepkg-args]
# Builds one PKGBUILD as builduser. If _MSYS_CROSS_MAKEPKG_CONFIG is set, --config is
# passed to BOTH the --packagelist dry-run and the real build (so skip-detection sees
# the right CARCH/PKGEXT → correct output names; otherwise the dry-run predicts the
# wrong names and skip-detection never fires — harmless but the build always re-runs).
build_pkg() {
    local pkg_dir="$1" makepkg_args="${2:--fCd --skippgpcheck}"
    local cfg_args=()
    [ -n "${_MSYS_CROSS_MAKEPKG_CONFIG:-}" ] && cfg_args=(--config "$_MSYS_CROSS_MAKEPKG_CONFIG")

    # Set up build directories (needed for --packagelist dry-run and actual build).
    # Per-target packages (gcc/binutils, selected by _MSYS_CROSS_TARGET) get a
    # target-suffixed BUILDDIR so the per-target build trees don't collide and the
    # post-build `rm -rf "$BUILDDIR"` reclaims each target's tree independently.
    export BUILDDIR="$PROJECT_ROOT/build/$pkg_dir${_MSYS_CROSS_TARGET:+-$_MSYS_CROSS_TARGET}"
    mkdir -p "$BUILDDIR" "$PKGDEST" "$SRCDEST" "$LOGDEST"
    chown -R builduser:builduser "$PROJECT_ROOT/build" "$PKGDEST" "$SRCDEST" "$LOGDEST"

    # Compute expected output packages via makepkg --packagelist (dry-run). Forward
    # _MSYS_CROSS_TARGET (runuser scrubs env) so the dry-run names match the build.
    # With a darwin --config, the conf supplies CARCH/PKGEXT so the names match too.
    local pkglist
    pkglist=$(cd "$PROJECT_ROOT/pkgs/$pkg_dir" && runuser -u builduser -- env \
                ${_MSYS_CROSS_TARGET:+_MSYS_CROSS_TARGET="$_MSYS_CROSS_TARGET"} \
                makepkg "${cfg_args[@]}" --packagelist 2>/dev/null) || true

    # Skip if all expected packages already exist
    local all_exist=true
    if [ -n "$pkglist" ]; then
        while IFS= read -r p; do
            [ -f "$p" ] || { all_exist=false; break; }
        done <<< "$pkglist"
    else
        all_exist=false
    fi

    if $all_exist; then
        echo ""
        echo "===== Skipping $pkg_dir (already built) ====="
        while IFS= read -r f; do echo "  $(basename "$f")"; done <<< "$pkglist"
        return 0
    fi

    echo ""
    echo "===== Building $pkg_dir ====="
    cd "$PROJECT_ROOT/pkgs/$pkg_dir"
    run_as_builduser makepkg "${cfg_args[@]}" $makepkg_args

    # Reclaim this package's scratch tree now that its .pkg.tar.* is in PKGDEST.
    # Each package has an isolated BUILDDIR and no later package reads a prior
    # one's build tree (outputs live in PKGDEST + INSTALL_PREFIX), so this keeps
    # peak disk at ~one toolchain build at a time. Skip detection re-derives from
    # the PKGBUILD + PKGDEST, so removing BUILDDIR doesn't break re-runs.
    echo "----- Cleaning build dir: $BUILDDIR -----"
    rm -rf "$BUILDDIR"
}

install_local() {
    local pattern="$1"
    echo "--- Installing $pattern ---"
    mkdir -p "$INSTALL_PREFIX/var/lib/pacman"
    pacman -Udd --noconfirm --overwrite='*' --root="$INSTALL_PREFIX" "$PKGDEST"/$pattern 2>&1 | tail -3
}
