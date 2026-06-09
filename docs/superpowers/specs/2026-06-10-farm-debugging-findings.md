# sccache-dist farm migration — debugging findings (2026-06-09/10)

Status of the `ci/sccache-dist-farm-migration` branch after an extended autonomous
debugging session. This records what broke, the root causes (all evidence-backed),
the fixes applied, and open recommendations.

## Where it stands

The migration (15-worker farm + single client container + S3 cache + zig-cc-via-
`sccache zig cc`) is **functionally wired and the build runs**, but two problems were
hit and fixed across several runs. The farm is **slow and somewhat unstable** for this
toolchain build — see "Recommendation".

## Problems found and fixed (in order)

### 1. Job-graph deadlock — FIXED (`d849c7e`, `03b9075`)
`build` had `needs: [build-prep-image, workers]`. `build` IS the coordinator; workers
stay up until the coordinator exits → `build` waited forever for never-ending workers.
Fix: `workers` and `build` both `needs: build-prep-image` only; never `build → workers`.
(Caught by the user from the Actions graph.)

### 2. Deps compiled in the prep Docker image — REFACTORED (`6144671`)
With one client container, baking deps in the image (the "build once for 12 cells"
reason) is moot. Split `build.sh` `prep` → `prep` (Steps 0-2: tools+zig+sysroots, still
baked) + new `deps` phase (Step 3), run in the build job so the linux deps compile
distributes. `all` still runs prep+deps for local dev.

### 3. builduser couldn't write the sccache cache dir — FIXED
The coordinator set `SCCACHE_DIR=$HOME/.cache/sccache` in ROOT's home; compiles run as
`builduser` (makepkg/build_deps refuse root). builduser couldn't create cache subdirs
there → `failed to create directory …/preprocessor: Permission denied` → **every compile
produced no object** → gmp's configure reported "no working compiler". Reproduced locally
with an unwritable `SCCACHE_DIR`. Fix: a builduser-owned cache dir
(`/opt/msys-cross/.sccache-cache`, `SCCACHE_DIR` override for all steps).

### 4. S3 cache never written (bucket stayed empty) — FIXED (`8c5dfdc`)
`Cache location` stayed `Local disk` despite the S3 env being set, so nothing reached
the `msys-cache` bucket. Root cause: the S3 **env vars didn't reliably reach the
sccache daemon** started through `runuser` (the daemon captures its backend at start).
Fix: select the S3 backend via the sccache **config file** (`[cache.s3]` section), which
the daemon reads deterministically; AWS creds still come from env (sccache's only source
for creds). **Verified locally**: `[cache.s3]` file + env creds → `Cache location: s3,
name: msys-cache`, a unique compile writes an object to the bucket (object count grew).

### 5. zig-cc-via-`sccache zig cc` distribution gate — FIXED (`adc907e`)
`zig-common.sh` re-exec'd as `sccache <self>` → sccache classified it as a generic cc →
never distributed. Changed to `exec sccache zig cc …` so `is_zig` fires. Verified the
emitted argv is `[zig, cc, -target …]` and `-Wall` is filtered.

## Non-issues (ruled out with evidence)
- **`zig: error: version '.2.11' in target triple 'x86_64-unknown-linux-gnu.2.11' is
  invalid`** — appears 31× but ALL inside libtool **configure probes** (preceded by
  "checking …"), ZERO in real TU compiles. Non-fatal: configure treats the probe failure
  as "feature absent" and continues. NOT the build failure. (clang normalizes the wrapper's
  valid `x86_64-linux-gnu.2.11` to `x86_64-unknown-linux-gnu.2.11` during a probe, which
  zig then rejects — cosmetic.)

## The phases build failure (run 27214110825)
`Build linux phases` failed during the gcc-mingw64 chain (libiberty archive). Stats:
`Compilations 4464`, **`Compilation failures 271`**, **`Failed distributed compilations
412`**, `Cache errors (C/C++) 110`, `Cache hits 603` (12% — caching worked, to disk).
Interpretation: ~9% of distributed compiles failed, and because the **local fallback was
also broken** (problems 3+4), those TUs produced no `.o` → archive failed. With problems
3+4 fixed, dist failures should fall back to a working local+S3 sccache and recover.

## Performance observations (important)
- **deps via dist ≈ 12 min**: autotools `configure` is latency-bound (hundreds of serial
  tiny probe compiles); dist adds round-trip latency to each → dist is **net-negative**
  for the configure-heavy deps. Consider building deps locally (`-j$(nproc)`, no dist) and
  reserving the farm for the phases.
- **phases via dist ≈ 50+ min** and slow: per-TU dist round-trip overhead is high for
  gcc/binutils/clang's many small TUs; a local `-j` build may be comparable or faster.
- **worker attrition**: ~4/15 workers exited (`completed/failure`, empty logs) during the
  long build — likely GitHub reclaiming ephemeral runners. `min-workers: 8` keeps the build
  alive, but it degrades the farm. Long builds + ephemeral workers don't mix well.
- **dist load imbalance** (665 vs 74 jobs across 15 servers): the scheduler
  (`handle_alloc_job`) iterates a HashMap and `break`s on the first server with `load==0`,
  so HashMap order favors early servers when many are idle. Cosmetic at this scale (short
  jobs drain fast; no throughput loss), but uneven. A real fix is a round-robin/random
  tie-break in the **fork** scheduler (`xdqi/sccache`), out of scope for the consumer repo.

## Recommendation (for the user to decide)
The genuinely valuable parts of the migration are the **single client container** and the
**S3 cache** (cross-run reuse). The **dist farm** is, for this toolchain build, slow
(round-trip-bound) and unstable (worker attrition, ~9% dist failures). Options:
1. **Keep S3, drop dist**: compile locally (`-j$(nproc)`) with `sccache` → S3. Fast,
   reliable, gives the cache win. Simplest path to consistently green + fast builds.
2. **Keep the farm but only for phases**: build deps locally (no dist), distribute phases.
3. **Invest in the fork**: fix dist reliability (the 9% failure rate) + scheduler balance.
   Largest effort, touches the shared `xdqi/sccache` repo.

My recommendation: **Option 1** unless the farm's parallelism is proven to beat local
`-j` after the reliability fixes. The S3 cache is where the real speedup is (warm-cache
reruns are near-instant regardless of dist).

## Decision executed (2026-06-10, commit 7ed5d91)
Went with **Option 1**: the sccache-dist farm (workers job + coordinator step) was
**removed**. The `build` job now compiles everything **locally** in the one container with
`MAKEFLAGS=-j$(nproc)` and sccache caching to S3 (S3 backend selected via the `[cache.s3]`
config file — the robust method; env-based selection was flaky through `runuser`). The
workflow is now 2 jobs (`build-prep-image` + `build`); `build needs build-prep-image` only.

The decisive evidence that tipped it from "slow/unreliable" to "remove": run 27219990154's
real fatal error was `zig c++` failing to find `<memory>` (a libc++ header) in
`gcc-16.1.0/libcody/buffer.cc` — and `zigc++ -c buffer.cc` compiles fine **locally**, so the
header loss is purely a distributed-compile defect. Three independent dist-only failure
classes (this, the `-target` mangling, the ~9% generic dist failures) made the farm
untenable for this build without fork-level fixes.

**To re-enable dist later:** re-add the coordinator step + `workers` matrix job (see git
history at commit `cf6824f`/`8c5dfdc`), append the coordinator's `[dist]` config to
builduser's sccache config, and set `MAKEFLAGS=-j$SCCACHE_J` — but only after the three
`xdqi/sccache` fork bugs above are fixed and verified.

## Verified outcome of the local-build run (27224119863)
- **S3 caching WORKS** (the headline fix): stock sccache v0.10.0 + the `zigcc`-as-clang
  wrapper (reverted to the proven `sccache <self>` form) + S3 via env/`[cache.s3]` → the
  bucket grew from 3 to >1000 objects during one run. The fork/dist/builduser-server
  complications were what had kept S3 disk-only; removing them fixed it.
- **The build is reliable** (no dist failure modes): deps green, all early steps green.
- **But the cold build is SLOW** (~70+ min for the linux phases alone). Reason: the phase
  loop builds the four binutils→gcc chains + clang **serially** in the one container on a
  ~4-core runner. This is the cost of "one client container" (the user's explicit choice,
  "把12路并行再合并回来"): the old 12-cell topology built the chains in PARALLEL across
  runners, which was faster. Warm-cache reruns are far faster (S3 cache hits), but the cold
  build trades wall-clock for the single-container simplicity.
  - If cold-build speed matters more than single-container: the **original 12-cell topology**
    (parallel chain cells, each stock sccache→S3) was both fast and reliable — that's the
    real alternative to weigh, not the farm.
