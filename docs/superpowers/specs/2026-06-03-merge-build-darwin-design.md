# Design: Merge `build-darwin.sh` into `build.sh`

Date: 2026-06-03
Status: Approved (design), pending implementation plan

## Goal

Collapse the two near-identical build entrypoints
(`scripts/build.sh` = Linux x86_64, `scripts/build-darwin.sh` = arm64 macOS host)
into a single `scripts/build.sh` that takes a target selector. The two scripts
share ~85% of their structure (the same Steps 0–6); the merge removes that
duplication and makes the Linux/darwin divergence explicit and small.

This is a focused, standalone cleanup. It is **not** the larger `scripts/`
restructure (subdirectories + kebab-case rename) — that is deferred. No script is
renamed or moved here; only `build.sh` is rewritten and `build-darwin.sh` is
deleted.

## Invocation

```
bash scripts/build.sh            # Linux x86_64 (default, unchanged CLI)
bash scripts/build.sh darwin     # arm64 macOS 11.0 host
```

`TARGET="${1:-linux}"`, validated against `linux|darwin` (anything else: error + exit).

## Target divergence — the full matrix

After the merge, all per-target differences are expressed up front as variables.
The shared body (Steps 0–6) reads those variables and has a few inline
`if [ "$TARGET" = darwin ]` blocks where darwin does *extra* work.

| Knob | linux | darwin |
|---|---|---|
| `ZIG_TARGET` | `x86_64-linux-gnu.2.11` (set explicitly; was previously unset/defaulted) | `aarch64-macos.11.0` |
| `PKGDEST` | `repo/` | `repo-darwin/` |
| `DEPS_INSTALL` / `DEPS` | `deps/install-$ZIG_TARGET` (unified — see note 1) | `deps/install-$ZIG_TARGET` |
| `INSTALL_PREFIX` | `build/install-prefix-$ZIG_TARGET` (unified — see note 2) | `build/install-prefix-$ZIG_TARGET` |
| `_MSYS_CROSS_HOST` | `x86_64-linux-gnu` | `aarch64-apple-darwin20` |
| `_MSYS_CROSS_DUMPSPECS` | unset (native xgcc) — **must stay unset on linux** (note 3) | `1` |
| `_MSYS_CROSS_MAKEPKG_CONFIG` | unset | `$SCRIPTS_DIR/makepkg-darwin-arm64.conf` |
| host pacman pkgs | union list (note 4) | union list |
| makepkg args | `build_pkg` default (`-fCd --skippgpcheck`) | `-fCd --skippgpcheck --nocheck --ignorearch` |
| Step 2 extra | — | `chown -R builduser specs-helper` after sysroot prep |
| Step 3 deps | `run_as_builduser bash build_deps.sh` | `bash build-deps-darwin.sh` (root) + `chown DEPS_INSTALL` |
| Step 4b clang | **built** | **skipped** |
| Step 5 db name | `msys-cross` | `msys-cross-darwin` |
| Step 6 installer | default env | `INSTALLER_DIR=installer-darwin`, `PACMAN_CONF=…/pacman-darwin.conf`, `BOOTSTRAP_TARBALL=…/bootstrap-darwin.tar.xz` |

### Notes / decisions

1. **`DEPS_INSTALL` unified to `$ZIG_TARGET` scheme.** Linux's `build.sh` currently
   overrides `DEPS_INSTALL=build/deps-install`, but both `build_deps.sh:22` and
   `msys-cross-common.sh:25` already *default* to
   `deps/install-${ZIG_TARGET:-x86_64-linux-gnu.2.11}`. Dropping the linux override
   makes linux use that same default path, so the two targets derive deps the same
   way. Verified safe: no CI cache keys on this path (CI caches only
   `build/sccache-cache`, `build/.deps-src`, `build/sources`).

2. **`INSTALL_PREFIX` unified to `build/install-prefix-$ZIG_TARGET`.** Currently
   linux uses `build/install-prefix` and darwin `build/install-prefix-darwin`.
   Keying both on `$ZIG_TARGET` unifies them. `msys-cross-common.sh:29` defaults to
   `build/install-prefix` only when `INSTALL_PREFIX` is unset — `build.sh` always
   exports it, so the lib default is never consulted in CI. Verified safe: not a CI
   cache path.

3. **`_MSYS_CROSS_DUMPSPECS` stays darwin-only.** It is read by the GCC/cygwin-gcc
   PKGBUILDs to enable the wine specs-helper path (Canadian-cross). On linux the
   native xgcc runs directly and this var must remain unset, or linux would change
   behavior. This is the one "extra env" that is NOT set on linux.

4. **Host pacman packages: install the union on both targets.** One list
   `base-devel curl git zstd sudo llvm meson cmake gperf wine`. `meson/cmake/gperf`
   (from-source pacman makedeps) and `wine` (darwin specs-helper) are harmless when
   present-but-unused on the other target. Removes the per-target package-list
   branch.

## Shared body structure (after merge)

```
TARGET = ${1:-linux}; validate
SCRIPTS_DIR / PROJECT_ROOT  (unchanged)

# ---- per-target config block (case $TARGET) ----
#   sets: ZIG_TARGET, PKGDEST, _MSYS_CROSS_HOST, (_MSYS_CROSS_DUMPSPECS),
#         (_MSYS_CROSS_MAKEPKG_CONFIG), MAKEPKG_ARGS, BUILD_CLANG, DB_NAME,
#         INSTALLER_DIR/PACMAN_CONF/BOOTSTRAP_TARBALL (darwin only)
# ---- shared path exports keyed on ZIG_TARGET ----
#   DEPS_INSTALL, DEPS, INSTALL_PREFIX, SRCDEST, LOGDEST, BOOTSTRAP_PREFIX,
#   ZIG_PATH, DEPS_CACHE, JOBS

mkdir -p …; banner echo
export PATH="$INSTALL_PREFIX/bin:$PATH"

Step 0  host tools: pacman -Syu + install union HOST_PKGS; create builduser
        source build-common.sh
Step 1  prepare-zig.sh
Step 2  prepare-build-sysroot.sh
        if darwin: chown specs-helper
Step 3  if darwin: bash build-deps-darwin.sh (root) + chown DEPS_INSTALL
        else:      run_as_builduser bash build_deps.sh
Step 4  build_pkg "<pkg>" "$MAKEPKG_ARGS"   (foundation, binutils loop, gcc loop, cygwin-gcc)
        install_local …
Step 4b if $BUILD_CLANG: build_pkg msys-cross-clang; install_local
Step 5  repo db using $DB_NAME  (rm old; repo-add loop)
Step 6  installer: export INSTALLER_DIR/PACMAN_CONF/BOOTSTRAP_TARBALL (darwin); bash build_installer.sh
final   banner + package listing (+ df on darwin)
```

`build_pkg`'s 2nd arg is `${2:--fCd --skippgpcheck}` — `:-` fires on unset **or
empty**, so an omitted/empty 2nd arg uses the default. Linux therefore **omits**
the arg (keeps the default); darwin passes the `-fCd --skippgpcheck --nocheck
--ignorearch` string. No change to `build-common.sh`.

## Blast radius / callers to update

- **`.github/workflows/build.yml:278`** — `bash scripts/build-darwin.sh` →
  `bash scripts/build.sh darwin`. (Line 141 `bash scripts/build.sh` unchanged.)
  Both jobs keep distinct `runner.os`-keyed caches; no collision.
- **`scripts/build-darwin.sh`** — deleted.
- **`README.md`** — verified: no `build-darwin.sh` mention, so no edit needed.
- Docs under `docs/` mentioning `build-darwin.sh` are historical specs/plans; leave
  as-is (they describe prior state). CI is the only caller that changes.

## Out of scope (explicitly deferred)

- Renaming `build_deps.sh` / `build_installer.sh` / etc. to kebab-case.
- Moving scripts into `lib/ deps/ zig/ conf/ test/` subdirectories.
- Touching `build-common.sh`, `msys-cross-common.sh`, `zig-common.sh`,
  `build-deps-darwin.sh`, `build_deps.sh` internals.

## Verification

The real proof is a green build, but a full toolchain build is heavy. Tiered:

1. **Static**: `bash -n scripts/build.sh` (syntax). (`shellcheck` not installed here.)
2. **Dry-trace**: run the per-target config block in isolation for both
   `TARGET=linux` and `TARGET=darwin`, print the resolved env (PKGDEST, ZIG_TARGET,
   DEPS_INSTALL, INSTALL_PREFIX, _MSYS_CROSS_*, MAKEPKG_ARGS, DB_NAME, BUILD_CLANG)
   and confirm each matches the values the two original scripts produced.
3. **Equivalence check**: diff the resolved linux env against pre-merge `build.sh`
   behavior and the darwin env against pre-merge `build-darwin.sh` behavior. The
   only intended differences are the two unified paths (DEPS_INSTALL,
   INSTALL_PREFIX) called out in notes 1–2.
4. **CI** (authoritative): both `build.yml` jobs run to completion on a branch.
