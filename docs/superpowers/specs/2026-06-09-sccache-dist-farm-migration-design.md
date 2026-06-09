# Migrate msys2-cross CI to the sccache-dist compile farm

Date: 2026-06-09

## Goal

Replace the current 12-cell parallel build topology with the published
`xdqi/sccache-dist-action` compile farm: **15 worker runners** distribute every
`zig cc` translation unit, and the 12 parallel "client" cells collapse into a
**single client (coordinator) container** that drives the whole build. The
SeaweedFS S3 compile cache (`msys-cache` @ `s3.kosaka.moe`) is kept unchanged
and used alongside distribution.

This also fixes the `zig cc` distribution gate: the current `zig-common.sh`
re-execs as `sccache <self>`, which sccache classifies as a generic clang-ish
wrapper, so the `Zig` toolchain is never packaged and **every TU compiles
locally** (the farm would sit idle). The wrapper is changed to invoke
`sccache zig cc` so sccache's `is_zig` gate fires and TUs distribute.

## Background — why the current shape can't just gain workers

Current `.github/workflows/build.yml`:

- `build-prep-image`: bakes Steps 0-3 (host tools, zig, MSYS2 sysroots, static
  deps) for both hosts into a container image pushed to ghcr, SHA-tagged.
- `cell` matrix: `host: [linux, darwin] × phase: [others, chain:mingw64,
  chain:mingw32, chain:ucrt64, chain:cygwin, clang]` = 12 cells, each running
  `container: prep-image` and each its own `mozilla-actions/sccache-action`
  client against S3. **This is the "12-way parallel client" being collapsed.**
- `collect-linux` / `collect-darwin`: fan-in jobs that download cell artifacts,
  run `assemble`, and publish a GitHub Release per host.

Parallelism today is **per-package, across cells**. The migration moves
parallelism to **per-translation-unit, across the farm**, so the 12 cells are no
longer needed — one container can build all phases while the 15 workers absorb
the compile load.

## Verified facts grounding this design

- **S3 reachability (this session):** the CI identity in
  `build/seaweedfs-provision.sh` (`GK7637044d…` / endpoint `https://s3.kosaka.moe`,
  bucket `msys-cache`, region `auto`, path-style) was exercised with
  List/PUT/GET/DELETE — all 2xx. The cache backend works.
- **`zig cc` distribution gate** (forked sccache, `~/sccache`
  `src/compiler/compiler.rs:1497`): distribution fires only when
  `is_zig(executable)` (the invoked file-stem is literally `zig`) **and**
  `args[0] ∈ {cc, c++}`. The current `sccache <self>` re-exec fails the first
  test → no `ZigToolchainPackager` → local fallback for every TU.
- **Cross target rides through:** `src/compiler/zig.rs:rewrite_dist_arguments`
  injects **no** `-target` and passes a user-supplied `-target` untouched. So
  `-target x86_64-linux-gnu.2.11` (and the macOS triple) supplied by the wrapper
  reaches the worker's `zig cc` → correct cross objects. The 2026-06-09 spike
  proved all four msys2-cross triples distribute with 0 local fallback.
- **Worker→coordinator binding** (`internal/worker/worker.go`): each worker
  hard-binds to a single `<run-prefix>-coordinator` host and tears itself down
  when that coordinator goes offline. ⇒ a worker pool serves **exactly one**
  coordinator. (This is why darwin folds into the same coordinator rather than
  running as a second, contending coordinator — see "Decisions".)

## Target topology

```
┌─ workers ────────────────────────────────┐     ┌─ build (single client container) ──────────┐
│ strategy.matrix.idx = 1..15               │     │ container: <prep-image>  (zig + sysroots)   │
│ runs-on: ubuntu-latest  (NO prep image)   │ ◄── │ uses: xdqi/sccache-dist-action mode:coord   │
│ uses: xdqi/sccache-dist-action            │     │   expected-workers: 15  min-workers: 8       │
│   mode: worker, worker-index: ${idx}      │     │   wait-timeout: 600s                         │
│   oauth-secret, tags: tag:ci              │     │ ── then, in the SAME container: ──           │
└───────────────────────────────────────────┘     │ export SCCACHE_BUCKET/ENDPOINT/AWS_* (S3)   │
              one farm, run-prefix=run_id           │ build.sh linux others→chains→clang -jSCCACHE_J│
                                                    │ assemble linux + publish release            │
                                                    │ if push:                                     │
                                                    │   build.sh darwin others→chains→clang -jJ    │
                                                    │   assemble darwin + publish release          │
                                                    └──────────────────────────────────────────────┘
```

### Jobs after migration

| Job | Change |
|-----|--------|
| `build-prep-image` | **Unchanged.** The coordinator container still needs zig + sysroots. |
| `workers` | **New.** Matrix `idx: 1..15`, `runs-on: ubuntu-latest`, runs `mode: worker`. Plain runners + preinstalled Docker; **not** the prep image. |
| `build` | **New, replaces `cell` + `collect-linux` + `collect-darwin`.** One `container: <prep-image>` job: coordinator step, then linux phases, assemble+release; then on push, darwin phases, assemble+release. |

### Build step shape inside the `build` job

1. Install kernel/build deps if any are missing on the prep image (likely none).
2. `uses: xdqi/sccache-dist-action` with `mode: coordinator`,
   `expected-workers: 15`, `min-workers: 8`, `wait-timeout: 600s`,
   `oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}`, `tags: tag:ci`.
   This exports `SCCACHE_J`, `SCCACHE_WORKERS_ONLINE`, `SCCACHE_DIR`,
   `SCCACHE_DIST_FALLBACK` and writes `~/.config/sccache/config`.
3. **Configure S3 client cache AFTER the coordinator step** (memory: S3 wins
   over the coordinator's local `SCCACHE_DIR` only if set later). Export into
   `$GITHUB_ENV`: `SCCACHE_BUCKET`, `SCCACHE_ENDPOINT`, `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`, `SCCACHE_REGION=auto`, `SCCACHE_S3_USE_SSL=true`,
   `SCCACHE_S3_KEY_PREFIX=msys2-cross`, `SCCACHE_IDLE_TIMEOUT=0`. Same secrets the
   12 cells used today.
4. **Export `MAKEFLAGS="-j${SCCACHE_J}"`** into `$GITHUB_ENV` (after the
   coordinator step), then build linux phases sequentially in one process each,
   e.g. `for ph in others chain:mingw64 chain:mingw32 chain:ucrt64 chain:cygwin
   clang; do bash scripts/build.sh linux "$ph"; done`.

   **Why `MAKEFLAGS` is the correct knob (verified):** package compiles run via
   `makepkg`, which reads `-j` from `MAKEFLAGS` in its environment. `MAKEFLAGS`
   is currently set **nowhere** (`scripts/makepkg-*.conf` don't set it), so today
   each package compiles **serially** and throughput comes only from the 12
   parallel cells. `build.sh`'s `JOBS=$(nproc)` feeds `build_deps.sh` (a *prep*
   concern, already baked into the image) — **not** the per-package PKGBUILD
   compiles. `run_as_builduser` uses `runuser -w PATH` which **preserves exported
   env** (only PATH is reset), so an exported `MAKEFLAGS` rides through to
   `makepkg`→`make` as builduser. Setting `MAKEFLAGS=-j$SCCACHE_J` is what makes
   each package's TUs fan out to the farm. The migration thus flips the model
   from *per-package-serial / cross-cell-parallel* to *per-package-`-j$SCCACHE_J`
   / phase-serial*.
5. `bash scripts/build.sh linux assemble`; publish release (push only) — logic
   lifted verbatim from `collect-linux`.
6. `if: github.event_name == 'push'`: repeat steps 4-5 for `darwin`
   (`build.sh darwin <phase>` … `assemble`), publish the darwin release —
   logic lifted from `collect-darwin`. Darwin is **not** built on PRs.

`SCCACHE_DIST_FALLBACK` stays `true` (default): a non-distributable input (`.S`,
`/dev/null` probe) compiles locally instead of failing the build.

## zig-common.sh change

Replace the sccache **self-re-exec** with a direct **`sccache zig cc`** hand-off.
The wrapper stays the front of the chain and keeps doing the work sccache cannot
see through:

- `zig_handle_dumpmachine "$@"` — stays FIRST and exits 0 on `-dumpmachine`,
  before sccache (sccache/clang would reject the versioned triple or run
  `zig -E`).
- `zig_filter_args "$@"` — stays; strips GCC-only `-Wall/-Wextra/-W/-Werror`,
  `-Wconditionally-supported`, `-Wshadow=local`, and the Mach-O ld64 flags.
- Then `exec` the real compile through sccache so the executable stem is `zig`
  and `args[0]` is the `cc`/`c++` subcommand:

```sh
# new zig_main tail (replaces zig_sccache_reexec + the final `exec zig …`)
local sccache="${SCCACHE_PATH:-}"
[ -z "$sccache" ] && sccache="$(command -v sccache 2>/dev/null || true)"
local xflag=()
[ "$mode" = c++ ] && $ZIG_IS_COMPILE && xflag=(-x c++)
if [ -n "$sccache" ]; then
    exec "$sccache" zig "$mode" "${xflag[@]}" -target "$ZIG_CC_TARGET" "${ZIG_ARGS[@]}" "${ZIG_WNO[@]}"
else
    exec zig "$mode" "${xflag[@]}" -target "$ZIG_CC_TARGET" "${ZIG_ARGS[@]}" "${ZIG_WNO[@]}"
fi
```

- `zig_sccache_reexec` and the `_ZIGCC_INNER` plumbing are **removed**.
- **`SCCACHE_C_CUSTOM_CACHE_BUSTER` is removed.** It existed because sccache
  hashed the *wrapper bytes* (which don't change on zig upgrade) and never saw
  the injected `-target`. With `sccache zig cc`, sccache detects the **real zig**
  (version via the Zig impl) and `-target` is a visible argument — both cache
  dimensions are captured natively, so the buster is redundant.
- **No-sccache fallback preserved:** local dev without sccache `exec zig …`
  directly (the `else` branch).
- The `-dumpmachine`, `c++ -x c++`, arg-filter, and ZIG_WNO behaviors are
  byte-for-byte preserved — only the sccache hand-off mechanism changes.

The `cc`/`c++` mode token still rides through correctly: the wrapper turns it
into `zig cc …` / `zig c++ …`, which is exactly what the forked Zig impl's
`zig_cc_subcommand` parses.

## What stays identical

- Prep image build, ghcr push, SHA-tag, `COPY . .` source baking.
- `scripts/build.sh` phase dispatch and every PKGBUILD; env files; release
  tag-numbering logic (`build-YYYYMMDD.N`, `build-darwin-YYYYMMDD.N`).
- Artifact/release contents (the `build` job assembles + releases inline rather
  than via separate collect jobs).
- The `SCCACHE_S3_*` secrets and their meaning.

## New prerequisites

- **`TS_OAUTH_SECRET`** repo secret — Tailscale OAuth client secret, with a
  `tag:ci` tagOwner in the tailnet ACL. Required by both worker and coordinator.
- Existing `SCCACHE_S3_BUCKET/ENDPOINT/KEY_ID/SECRET` — unchanged.

## Decisions (resolved during brainstorming)

1. **Single client container, phase-serial + TU-parallel.** One coordinator
   runs phases sequentially; `-j$SCCACHE_J` fans each package's compiles to the
   farm. (Not backgrounded phases — readability/attribution.)
2. **PKGBUILDs keep calling the `zigcc`/`zigc++` wrapper;** the wrapper hands off
   to `sccache zig cc`. (Not `CC="sccache zig cc"` directly — the wrapper still
   owns `-target`/filtering/`-dumpmachine`.)
3. **Plain `ubuntu-latest` workers**, not the prep image. The zig toolchain
   travels in the dist archive; pure-C cross needs no SDK on the worker (spike-
   proven).
4. **One farm; darwin folds into the SAME coordinator, back-to-back, push-only.**
   A second independent coordinator was considered but rejected: workers
   hard-bind to one `<run-prefix>-coordinator` and tear down when it exits, so
   two coordinators sharing a pool collide on hostname and the first to finish
   yanks the farm from the second. Two *separate* 15-worker farms (distinct
   run-prefix) would work but doubles runner usage on a push; declined in favor
   of the single-farm, sequential-darwin shape.
5. **`SCCACHE_C_CUSTOM_CACHE_BUSTER` removed** (now redundant).

## Known trade-offs / non-goals

- **Package compression & repo assembly are now single-container (~dual-core).**
  Previously each cell compressed its own packages in parallel across 12
  runners; now `makepkg` xz/zstd packaging and `repo-add` db assembly run in one
  container. This is an accepted regression of this topology. A follow-up could
  parallelize compression (e.g. `XZ_OPT`/`ZSTD_NBTHREADS`, or a small fan-out for
  the packaging stage) — **out of scope here.**
- **Distribution covers `zig cc` TUs only.** Configure-time probes, `.S`/asm,
  and darwin wine specs-helper invocations run on the coordinator (local) — by
  design, and already handled by `SCCACHE_DIST_FALLBACK`.
- **Darwin is push-only** (PRs build linux only), preserving today's PR behavior.
- **No change to the sccache-dist-action repo or the forked engine** — this is a
  pure consumer-side migration of msys2-cross's workflow + the zig wrapper.

## Success criteria

1. A push to `main` runs: 15 workers join the farm; the coordinator reports
   `≥8/15` online and a non-trivial `SCCACHE_J`.
2. `sccache --show-stats` (or `sccache -s`) after the linux build shows
   **distributed compiles > 0** and **0 (or near-0) `Forced to local fallback`**
   for `zig cc` TUs — i.e. the farm is actually used (the old wrapper would show
   100% local).
3. The linux pacman repo + bootstrap are assembled and a `build-YYYYMMDD.N`
   release is published, contents matching the pre-migration release.
4. On push, the darwin repo + `build-darwin-YYYYMMDD.N` release are published.
5. The S3 bucket `msys-cache` under prefix `msys2-cross/` gains objects across
   runs (cache populated), and a warm rerun shows cache hits.
6. A second worker pool is **not** spawned; exactly 15 worker jobs + 1 build job
   (+ the prep-image job) appear in the run.
