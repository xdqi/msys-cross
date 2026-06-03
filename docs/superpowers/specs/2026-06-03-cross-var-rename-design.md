# Design: Drop the leading underscore from the `_MSYS_CROSS_*` env family

Date: 2026-06-03
Status: Design — pending user review
Sequencing: **LAST.** Run only after the env-source-of-truth work
(`2026-06-03-env-source-of-truth-design.md`) and the build.sh/build-darwin.sh merge
(`2026-06-03-merge-build-darwin-design.md`) have landed. This is a pure mechanical
rename over the final, settled file set — doing it earlier would force rebasing that
work onto renamed vars.

## Motivation

The cross-build env contract uses a leading-underscore convention: `_MSYS_CROSS_HOST`,
`_MSYS_CROSS_BUILD`, `_MSYS_CROSS_TARGET`, `_MSYS_CROSS_DUMPSPECS`,
`_MSYS_CROSS_MAKEPKG_CONFIG`. The leading `_` normally signals "private/local," but
these are the opposite — a deliberately *shared*, cross-file/cross-process contract.
And only this handful of vars uses the prefix; the rest of the codebase's env
(`ZIG_TARGET`, `PKGDEST`, `DEPS`, `JOBS`, …) does not. A few vars carrying a lone
convention nobody else follows is the inconsistency to fix. Drop the `_`.

## Rename map

Two distinct kinds of var hide under the `_MSYS_CROSS_` prefix, and they get
DIFFERENT treatment:

**(a) The cross-file/cross-process contract — drop the leading `_`** (read across
scripts + PKGBUILDs + confs; the `_` wrongly implies "private"):
```
_MSYS_CROSS_HOST           -> MSYS_CROSS_HOST
_MSYS_CROSS_BUILD          -> MSYS_CROSS_BUILD
_MSYS_CROSS_TARGET         -> MSYS_CROSS_TARGET
_MSYS_CROSS_DUMPSPECS      -> MSYS_CROSS_DUMPSPECS
_MSYS_CROSS_MAKEPKG_CONFIG -> MSYS_CROSS_MAKEPKG_CONFIG
```
(`_MSYS_CROSS_ZLIB` is NOT here — the env spec §4b deletes it as dead code before this
sweep runs, so by now it no longer exists.)

**(b) The PKGBUILD-local that only LOOKS like a contract var — demote to a plain
local** (set + read only inside one `build()` in each of 2 PKGBUILDs; it is genuinely
private, so it should match the other locals `_startdir`/`_deps`/`_wrappers`, not the
namespaced contract):
```
_MSYS_CROSS_SPECS_GCC      -> _specs_gcc     (lowercase, keeps a leading _, drops MSYS_CROSS)
```

`MSYS_CROSS_ENV_LOADED` (the env-guard marker added by the env spec) is introduced
already-bare, so it is NOT part of this rename.

## Blast radius (measured)

65 occurrences across 9 files (counts pre-merge; the merge collapses the two
entrypoints, so post-merge the same tokens live in fewer files):

| File | notes |
|---|---|
| `scripts/build.sh` | entrypoint (post-merge: the single entrypoint) |
| `scripts/build-darwin.sh` | deleted by the merge — N/A if rename runs after merge |
| `scripts/build-common.sh` | `run_as_builduser` (slimmed by env spec) |
| `scripts/build_deps.sh` | configure `--host/--build` |
| `scripts/makepkg-linux-x86_64.conf` | (now sources env file) |
| `scripts/makepkg-darwin-arm64.conf` | (now sources env file) |
| `scripts/env-linux.sh` | NEW (env spec) — sets the vars |
| `scripts/env-darwin.sh` | NEW (env spec) — sets the vars |
| `pkgs/msys-cross-binutils/PKGBUILD` | incl. `sed`-injected `${_MSYS_CROSS_HOST:-…}` |
| `pkgs/msys-cross-gcc/PKGBUILD` | incl. `sed`-injected host/build + DUMPSPECS test |
| `pkgs/msys-cross-cygwin-gcc/PKGBUILD` | incl. `sed`-injected host/build + DUMPSPECS test |

Per-var (pre-merge): TARGET 26, HOST 12, BUILD 9, DUMPSPECS 6, MAKEPKG_CONFIG 4,
SPECS_GCC 8 (the latter only in gcc + cygwin-gcc PKGBUILDs). `ZLIB` (3 occ.) is gone —
deleted by env spec §4b before this runs.

**Collision check (done):** no bare `MSYS_CROSS_` (without leading `_`) exists anywhere
in `scripts/` or `pkgs/` today, so the (a)-substitution cannot clash. No bare
`_specs_gcc` exists either, so (b) is collision-free too.

## Approach

A single atomic commit, but TWO ordered `sed` passes (order matters — do the specific
SPECS_GCC rename FIRST so the generic prefix pass can't touch it):

```sh
files=$(grep -rl '_MSYS_CROSS_' scripts/ pkgs/)
# (b) FIRST: demote the PKGBUILD-local. Specific token, only in the 2 gcc PKGBUILDs.
echo "$files" | xargs sed -i 's/_MSYS_CROSS_SPECS_GCC/_specs_gcc/g'
# (a) THEN: the 6-var contract family loses its leading underscore.
echo "$files" | xargs sed -i 's/_MSYS_CROSS_/MSYS_CROSS_/g'
```

Order is load-bearing: if the generic pass ran first it would turn
`_MSYS_CROSS_SPECS_GCC` into `MSYS_CROSS_SPECS_GCC`, and the specific pass (matching
`_MSYS_CROSS_SPECS_GCC`) would then no longer fire — leaving the local wrongly
namespaced. Doing (b) first sidesteps this.

`sed` rewrites both plain shell references and the `sed`-injected configure strings
inside PKGBUILDs (those are just text in single-quoted `-e` expressions, so the outer
sweep edits them correctly). All in ONE commit — a half-renamed tree breaks the
contract (e.g. a conf exporting `MSYS_CROSS_HOST` while a PKGBUILD still reads
`_MSYS_CROSS_HOST`). Then hand-review the diff.

## Verification

1. **Post-sweep grep is empty:** `grep -rn '_MSYS_CROSS_' scripts/ pkgs/` returns
   nothing — every occurrence is now either `MSYS_CROSS_*` (contract) or `_specs_gcc`
   (the demoted local). Also confirm `grep -rn 'MSYS_CROSS_SPECS_GCC' scripts/ pkgs/`
   is empty (the local was demoted, NOT promoted to the bare namespace).
2. **Static:** `bash -n` + `shellcheck` on every edited `.sh`/`.conf`;
   `makepkg --printsrcinfo`/`--nobuild` smoke on the gcc + cygwin-gcc PKGBUILDs in the
   arch container to confirm the renamed `sed`-injected `GCC_FOR_TARGET="${_specs_gcc}"`
   strings still parse.
3. **Diff review:** `git show` — every hunk is either `_MSYS_CROSS_X` → `MSYS_CROSS_X`
   (contract) or `_MSYS_CROSS_SPECS_GCC` → `_specs_gcc` (local), nothing else.
4. **CI** (authoritative): both build jobs green on a branch.

## Out of scope

- Local helper vars (`_startdir`, `_deps`, `_wrappers`, `_project_root`, etc.) — these
  ARE genuinely local/private; their leading `_` is correct convention. Untouched.
- Filename snake_case → kebab-case (`build_deps.sh` etc.) — that is the separate
  larger `scripts/` restructure, not this change.
