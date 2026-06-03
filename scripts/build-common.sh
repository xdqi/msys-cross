# Shared helpers for the build entrypoints (scripts/build.sh = linux x86_64,
# scripts/build-darwin.sh = arm64 macOS host). SOURCED, not executed.
#
# Caller must have already set: SCRIPTS_DIR, PROJECT_ROOT, and the path exports
# (PKGDEST/SRCDEST/LOGDEST/DEPS/DEPS_INSTALL/BOOTSTRAP_PREFIX/INSTALL_PREFIX/
# ZIG_PATH/DEPS_CACHE/JOBS) — both entrypoints export these before sourcing, with
# their own values (the darwin entrypoint points PKGDEST/DEPS at darwin-specific
# dirs). Optional: MSYS_CROSS_MAKEPKG_CONFIG names a makepkg --config file forwarded
# to every makepkg invocation (the darwin pass uses makepkg-darwin-arm64.conf; the
# linux pass leaves it unset → unchanged behavior).

# The whole build runs as one unprivileged user (so the sccache server is single-uid
# and never hands another uid root-owned objects). Anything writable is chown'd to
# builduser before use.
run_as_builduser() {
    chown -R builduser:builduser "$PROJECT_ROOT/build" "$PKGDEST" "$SRCDEST" "$LOGDEST" 2>/dev/null || true
    # runuser preserves exported env and resets only PATH (util-linux 2.42.1, verified
    # in the arch build container). All build vars (ZIG_TARGET, MSYS_CROSS_*, DEPS*,
    # PKGDEST…, SCCACHE_* from $GITHUB_ENV, JOBS) are already exported, so they ride
    # through; we re-assert only PATH (which runuser DOES reset to a secure default).
    runuser -w PATH -u builduser -- env PATH="$PATH" "$@"
}

# build_pkg <pkg-dir> [makepkg-args]
# Builds one PKGBUILD as builduser. If MSYS_CROSS_MAKEPKG_CONFIG is set, --config is
# passed to BOTH the --packagelist dry-run and the real build (so skip-detection sees
# the right CARCH/PKGEXT → correct output names; otherwise the dry-run predicts the
# wrong names and skip-detection never fires — harmless but the build always re-runs).
build_pkg() {
    local pkg_dir="$1" makepkg_args="${2:--fCd --skippgpcheck}"
    local cfg_args=()
    [ -n "${MSYS_CROSS_MAKEPKG_CONFIG:-}" ] && cfg_args=(--config "$MSYS_CROSS_MAKEPKG_CONFIG")

    # Set up build directories (needed for --packagelist dry-run and actual build).
    # Per-target packages (gcc/binutils, selected by MSYS_CROSS_TARGET) get a
    # target-suffixed BUILDDIR so the per-target build trees don't collide and the
    # post-build `rm -rf "$BUILDDIR"` reclaims each target's tree independently.
    export BUILDDIR="$PROJECT_ROOT/build/$pkg_dir${MSYS_CROSS_TARGET:+-$MSYS_CROSS_TARGET}"
    mkdir -p "$BUILDDIR" "$PKGDEST" "$SRCDEST" "$LOGDEST"
    chown -R builduser:builduser "$PROJECT_ROOT/build" "$PKGDEST" "$SRCDEST" "$LOGDEST"

    # Compute expected output packages via makepkg --packagelist (dry-run). Forward
    # MSYS_CROSS_TARGET (runuser scrubs env) so the dry-run names match the build.
    # With a darwin --config, the conf supplies CARCH/PKGEXT so the names match too.
    local pkglist
    pkglist=$(cd "$PROJECT_ROOT/pkgs/$pkg_dir" && runuser -u builduser -- env \
                ${MSYS_CROSS_TARGET:+MSYS_CROSS_TARGET="$MSYS_CROSS_TARGET"} \
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
