# Design: Single source of truth for per-target build env

Date: 2026-06-03
Status: Design — pending user review
Sequencing: land THIS first; the build.sh/build-darwin.sh merge
(`2026-06-03-merge-build-darwin-design.md`) builds on top of it.

## Problem

The per-target cross-build environment
(`ZIG_TARGET`, `_MSYS_CROSS_HOST`, `_MSYS_CROSS_BUILD`, `_MSYS_CROSS_DUMPSPECS`) is
currently declared in **three** places, with the values duplicated:

1. **Entrypoint** (`scripts/build.sh` / `scripts/build-darwin.sh`) — `export`s them so
   the steps that run *outside* makepkg (`build_deps.sh`, `prepare-build-sysroot.sh`,
   `setup_zig_env` in `msys-cross-common.sh`) can read them.
2. **`run_as_builduser`** (`scripts/build-common.sh:18-35`) — re-forwards the same vars
   through a hand-maintained `runuser … env VAR=… VAR=…` list, because `runuser`
   re-launches the build as `builduser`.
3. **makepkg `.conf`** (`scripts/makepkg-darwin-arm64.conf` /
   `makepkg-linux-x86_64.conf`) — re-`export`s them *again*, because makepkg sources
   its `--config` file into a fresh subprocess for `build()`.

So e.g. `ZIG_TARGET=aarch64-macos.11.0` is written in three files. Editing a target
means editing all three in lockstep; drift is silent.

## Key findings (verified, not assumed)

- **`runuser` preserves exported env; it only resets `PATH`.** Tested in the actual
  build container (`archlinux/archlinux:base-devel`, util-linux 2.42.1): a plain
  `runuser -u <user> -- …` passes through exported `FOO`/`ZIG_TARGET`/`SCCACHE_DIR`
  unchanged, resetting only `PATH` to the secure default. So the long explicit `env`
  list in `run_as_builduser` defends against scrubbing that does not occur for
  exported variables. (util-linux also offers `-w/--whitelist-environment`, but it is
  unnecessary when the vars are already exported.)
- **Every path var the list forwards is already `export`ed** by the entrypoint
  (`ZIG_PATH`, `DEPS`, `DEPS_INSTALL`, `DEPS_CACHE`, `BOOTSTRAP_PREFIX`,
  `INSTALL_PREFIX`, `PKGDEST`, `SRCDEST`, `LOGDEST`, `JOBS`) or by `build_pkg`
  (`BUILDDIR`, `_MSYS_CROSS_TARGET`).
- **`SCCACHE_PATH` / `SCCACHE_DIR` / `SCCACHE_CACHE_SIZE`** are written to `$GITHUB_ENV`
  by CI (`build.yml:80-82`), so GitHub Actions injects them into the process
  environment of every later step — already exported, survive `runuser` automatically.
- **`_MSYS_CROSS_ZLIB`** is only ever set *inside* a PKGBUILD (makepkg-local, e.g.
  `binutils` `--prefix` logic); it is never set at the entrypoint level, so forwarding
  it from `run_as_builduser` is dead weight.

## Design

### 1. New per-target env file: `scripts/env-<target>.sh`

One tiny file per target, holding ONLY the portable exports (the subset that BOTH the
entrypoint shell AND the makepkg subprocess need). No makepkg-only knobs here.

`scripts/env-linux.sh`:
```sh
# Portable per-target build env. Sourced by: build.sh, makepkg-linux-x86_64.conf.
# Contains ONLY exports valid in a plain shell AND a makepkg subprocess (NOT CARCH/
# OPTIONS/PKGEXT — those are makepkg-only, set in the .conf).
export ZIG_TARGET="x86_64-linux-gnu.2.11"
export _MSYS_CROSS_HOST="x86_64-linux-gnu"
export _MSYS_CROSS_BUILD="x86_64-linux-gnu"
# _MSYS_CROSS_DUMPSPECS intentionally UNSET on linux (native xgcc runs directly).
export MSYS_CROSS_ENV_LOADED=1   # guard marker — see §5
```

`scripts/env-darwin.sh`:
```sh
export ZIG_TARGET="aarch64-macos.11.0"
export _MSYS_CROSS_HOST="aarch64-apple-darwin20"
# _MSYS_CROSS_BUILD stays unset -> build machine is Linux (cross mode).
export _MSYS_CROSS_DUMPSPECS=1
export MSYS_CROSS_ENV_LOADED=1   # guard marker (no leading _ — see naming spec)
```

> Naming note: the existing cross vars carry a leading underscore (`_MSYS_CROSS_*`);
> a later, final-phase change (`2026-06-03-cross-var-rename-design.md`) drops that
> prefix family-wide. The NEW marker is introduced already-bare
> (`MSYS_CROSS_ENV_LOADED`) so the rename sweep doesn't have to touch it. The
> `_MSYS_CROSS_HOST/BUILD/DUMPSPECS` shown here keep the leading `_` until that sweep.

These files are pure `export` statements — safe to `source` from any bash shell and
from inside makepkg. The `MSYS_CROSS_ENV_LOADED=1` marker lets consumers assert the
env was sourced (§5); verified in the arch container to survive both `runuser` and the
makepkg `--config` boundary into `build()`.

### 2. makepkg `.conf` sources the env file, then adds makepkg-only knobs

`makepkg-darwin-arm64.conf` (and the linux counterpart) change from re-declaring the
env to reusing it:
```sh
source /etc/makepkg.conf
source "$(dirname "${BASH_SOURCE[0]}")/env-darwin.sh"   # ZIG_TARGET, _MSYS_CROSS_*
# --- makepkg-only below (NOT in env-darwin.sh) ---
CARCH="arm64"
CHOST="aarch64-apple-darwin20"
OPTIONS=(!strip docs libtool staticlibs emptydirs zipman purge !debug !lto !autodeps)
STRIP_BINARIES=""; STRIP_SHARED=""; STRIP_STATIC=""
PKGEXT='.pkg.tar.zst'; SRCEXT='.src.tar.gz'
```
Note: makepkg `--config` files are sourced by makepkg with `${BASH_SOURCE[0]}` set to
the conf path, so `dirname` resolves to `scripts/` — the env file sits beside it.
**Verified** in the arch container: `makepkg --config /tmp/probe.conf` reports
`BASH_SOURCE[0]=/tmp/probe.conf`, `dirname=/tmp` — i.e. the conf's own directory. So
the `source "$(dirname "${BASH_SOURCE[0]}")/env-<target>.sh"` line resolves correctly.

### 3. Entrypoint sources the env file instead of inline exports

`build.sh` / `build-darwin.sh` replace their inline `export ZIG_TARGET=… / _MSYS_CROSS_*`
lines with:
```sh
source "$SCRIPTS_DIR/env-$TARGET.sh"
```
(For the not-yet-merged scripts: `build.sh` sources `env-linux.sh`, `build-darwin.sh`
sources `env-darwin.sh`.) Path vars (PKGDEST/DEPS/INSTALL_PREFIX/…) stay in the
entrypoint — they're computed from PROJECT_ROOT and ZIG_TARGET, not static per-target
constants, so they don't belong in the env file.

### 4. Slim `run_as_builduser` to rely on exported env + PATH only

`scripts/build-common.sh` `run_as_builduser` collapses from the ~15-line `env` list to:
```sh
run_as_builduser() {
    chown -R builduser:builduser "$PROJECT_ROOT/build" "$PKGDEST" "$SRCDEST" "$LOGDEST" 2>/dev/null || true
    # runuser preserves exported env and resets only PATH (util-linux 2.42.1, verified
    # in the arch build container). All build vars (ZIG_TARGET, _MSYS_CROSS_*, DEPS*,
    # PKGDEST…, SCCACHE_* from $GITHUB_ENV, JOBS) are already exported, so they ride
    # through; we re-assert only PATH (which runuser DOES reset to a secure default).
    runuser -w PATH -u builduser -- env PATH="$PATH" "$@"
}
```
`_MSYS_CROSS_ZLIB` is dropped (makepkg-local, never set at entrypoint). The explicit
`SCCACHE_*` naming is dropped (already exported via `$GITHUB_ENV`).

### 5. Remove the baked-in `${VAR:-default}` fallbacks (the *fourth* source)

The env-owned vars also have hard-coded defaults scattered across consumers — a fourth
place the canonical values live. With `env-<target>.sh` as the single source, these
defaults must go; a consumer reached without the env sourced should **fail loudly**,
not silently fall back to a Linux-shaped default (which on a darwin run produces a
subtly wrong, hard-to-diagnose build).

**Scope: layers A (entrypoint scripts) + B (PKGBUILDs). The zigcc wrapper keeps its
fallback** (layer C) so a bare `CC=scripts/zigcc` still works standalone.

**Guard mechanism — marker var, not per-var check.** The required-var *set differs by
target* (`_MSYS_CROSS_BUILD` only on linux, `_MSYS_CROSS_DUMPSPECS` only on darwin), so
"every var must be set" would wrongly fail. Instead env-`<target>`.sh exports a single
`MSYS_CROSS_ENV_LOADED=1` marker; consumers assert the marker (proving the env was
sourced) and then read each var **without** a `:-default`:
```sh
[ "${MSYS_CROSS_ENV_LOADED:-}" = 1 ] || {
    echo "ERROR: source scripts/env-<target>.sh (or build via build.sh) first" >&2
    exit 1
}
```
Verified in the arch container: the marker survives both the `runuser` drop to
builduser and the makepkg `--config` → `build()` boundary, so one check works in both
contexts A and B.

**Guard placement (no duplication):** the check lives ONCE at the top of
`msys-cross-common.sh` — which is sourced (at line 3, before any default is used) by
all three PKGBUILDs AND by `build_deps.sh`. Those four consumers inherit the guard for
free; only the `:-` default *removal* is edited per-file. `build-deps-darwin.sh` does
NOT source `msys-cross-common.sh`, so it carries its own copy of the 3-line guard.
Entrypoints source `env-<target>.sh` first (§3), so by the time anything sources
`msys-cross-common.sh` the marker is set.

**Defaults to strip (each → bare `$VAR` after the guard):**

Layer A (scripts) — strip `:-` defaults; guard inherited from msys-cross-common.sh
unless noted:
- `scripts/msys-cross-common.sh` — **hosts the guard** at top; strip `:25`
  `${ZIG_TARGET:-…}` (`_deps` path) and `:145`,`:155` `${ZIG_TARGET:-}` `case` guards
  → bare `$ZIG_TARGET`
- `scripts/build_deps.sh:22` `${ZIG_TARGET:-…}`, `:118` `${_MSYS_CROSS_BUILD:-…}`,
  `:119` `${_MSYS_CROSS_HOST:-…}` (guard inherited — already sources common at `:27`)
- `scripts/build-deps-darwin.sh:20` `${ZIG_TARGET:-aarch64-macos.11.0}` (**own guard**
  — does not source common)

Layer B (PKGBUILDs — strip the host/build `sed`-injected defaults):
- `pkgs/msys-cross-binutils/PKGBUILD:99,100` (`_MSYS_CROSS_BUILD`/`_MSYS_CROSS_HOST`)
- `pkgs/msys-cross-gcc/PKGBUILD:13,14` (build/host sed)
- `pkgs/msys-cross-cygwin-gcc/PKGBUILD:25` (build+host sed)

**Deliberately NOT stripped:**
- `scripts/zig-common.sh:19` `ZIG_CC_TARGET="${ZIG_TARGET:-x86_64-linux-gnu.2.11}"`
  (layer C — wrapper's standalone safety net; kept per decision).
- `_MSYS_CROSS_TARGET:-mingw64` in binutils/gcc PKGBUILDs (`:30`/`:45`) — this selects
  *which* Windows target, is NOT an env-`<target>`.sh var, and the build always sets it
  explicitly in the per-target loop. Out of scope for this change.
- `_MSYS_CROSS_DUMPSPECS:-0` in gcc/cygwin-gcc PKGBUILDs (`:143`/`:140`) — read as
  "is it `1`?", so unset is a *meaningful* value (off = linux native xgcc), not a
  stand-in for a missing source. The marker guard already proves env was sourced;
  `:-0` here is a legitimate off-switch default. **Kept.**

## Net result

| Var | before (declaration + default sites) | after |
|---|---|---|
| `ZIG_TARGET` | 6 (entry, conf, builduser-list, + 3 `:-` defaults) | 1 (`env-<target>.sh`) + zigcc safety-net fallback |
| `_MSYS_CROSS_HOST` | 6 (3 set + 3 `:-` defaults across scripts/PKGBUILDs) | 1 |
| `_MSYS_CROSS_BUILD` | 5 (2 set + 3 `:-` defaults) | 1 |
| `_MSYS_CROSS_DUMPSPECS` | 3 set (+ `:-0` off-switch, kept) | 1 (the `:-0` off-switch stays) |
| `run_as_builduser` env list | ~15 lines | 1 line (PATH only) |
| baked-in `${VAR:-default}` (layers A+B) | ~10 sites | 0 (replaced by marker guard) |

## Blast radius

- **New**: `scripts/env-linux.sh`, `scripts/env-darwin.sh` (set vars + marker).
- **Edited (scripts)**: `scripts/build.sh`, `scripts/build-darwin.sh` (source env file),
  `scripts/makepkg-linux-x86_64.conf`, `scripts/makepkg-darwin-arm64.conf` (source env
  file + keep only makepkg-only knobs), `scripts/build-common.sh` (slim
  `run_as_builduser`), `scripts/build_deps.sh` + `scripts/build-deps-darwin.sh` +
  `scripts/msys-cross-common.sh` (strip `:-` defaults, add marker guard).
- **Edited (PKGBUILDs)**: `pkgs/msys-cross-binutils`, `pkgs/msys-cross-gcc`,
  `pkgs/msys-cross-cygwin-gcc` PKGBUILDs (strip host/build `:-` defaults, add marker
  guard). These already `source msys-cross-common.sh`, so the guard can live there once
  and be inherited — see implementation note below.
- **No change**: CI (`build.yml` still calls the same entrypoints),
  `prepare-build-sysroot.sh`, `zig-common.sh` (keeps its fallback).
- The later merge spec consumes this: merged `build.sh` does `source env-$TARGET.sh`.

**Implementation note (avoid guard duplication):** the three PKGBUILDs all
`source .../msys-cross-common.sh` at top. Put the marker guard once in
`msys-cross-common.sh` (which is sourced by every PKGBUILD and by `build_deps.sh`),
rather than copy-pasting it into each PKGBUILD. `build-deps-darwin.sh` (which does NOT
source msys-cross-common.sh) gets its own one-line guard.

## Verification

1. **Static**: `bash -n` + `shellcheck` on the two new env files, both confs, and
   `build-common.sh`.
2. **Source-equivalence**: for each target, `source env-<target>.sh && env | sort` and
   confirm the exact set/values of `ZIG_TARGET`/`_MSYS_CROSS_*` matches what the old
   entrypoint + conf produced (esp. that `_MSYS_CROSS_DUMPSPECS` is set only on darwin
   and `_MSYS_CROSS_BUILD` only where it was before).
3. **makepkg conf sourcing**: `BASH_SOURCE`-based resolution already verified (see
   §2 note). Re-confirm the real confs source cleanly end-to-end with a minimal
   `makepkg --config scripts/makepkg-darwin-arm64.conf --nobuild` probe.
4. **runuser passthrough**: a container smoke test — export the build vars, call the new
   one-line `run_as_builduser` with a probe that prints them, confirm all survive and
   PATH is the intended one.
5. **CI** (authoritative): both `build.yml` jobs green on a branch.

## Out of scope

- The entrypoint merge (separate, later spec).
- Renaming/relocating scripts into subdirectories (the larger restructure).
- Touching the `zig-common.sh` wrapper env (`ZIG_CC_TARGET` derivation) — it already
  reads `ZIG_TARGET` and needs no change.
