# sccache-dist Farm Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate msys2-cross CI from the 12-cell parallel build to the `xdqi/sccache-dist-action` farm — 15 worker runners distribute every `zig cc` TU, and the 12 client cells collapse into one coordinator container; the SeaweedFS S3 cache is kept.

**Architecture:** Two changes. (1) `scripts/zig-common.sh` stops re-execing as `sccache <self>` and instead `exec`s `sccache zig cc …`, so sccache's `is_zig` gate fires and TUs distribute (and `SCCACHE_C_CUSTOM_CACHE_BUSTER` is dropped). (2) `.github/workflows/build.yml` replaces the `cell` matrix + two `collect` jobs with a `workers` matrix (idx 1..15, `mode: worker`) and a single `build` coordinator container that runs all linux phases with `MAKEFLAGS=-j$SCCACHE_J`, assembles + releases, then on push does darwin back-to-back.

**Tech Stack:** GitHub Actions YAML, bash (zig wrapper / build.sh), `xdqi/sccache-dist-action@v0.0.4`, sccache (S3 backend), zig cc, the forked sccache `Zig` engine (already published in the action's release).

**Spec:** `docs/superpowers/specs/2026-06-09-sccache-dist-farm-migration-design.md`

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `scripts/zig-common.sh` | The zigcc/zigc++ wrapper body: arg filtering, `-dumpmachine`, `-target` injection, sccache hand-off | **Modify** — replace `zig_sccache_reexec` + final `exec zig` with a single `exec [sccache] zig <mode> …`; remove the cache-buster |
| `scripts/zigcc`, `scripts/zigc++`, `scripts/zigcc-native`, `scripts/zigc++-native` | Thin `source zig-common.sh <mode>` shims | **Modify (comments only)** — the "sccache probes via $0" rationale is now stale; refresh the comment. No logic change. |
| `.github/workflows/build.yml` | The whole CI topology | **Modify** — keep `build-prep-image`; replace `cell` + `collect-linux` + `collect-darwin` with `workers` (×15) + one `build` job |

No new files. No test framework exists for CI YAML / the bash wrapper, so verification uses `shellcheck`, a local zig-wrapper classification dry-run, `python3 -c yaml.safe_load`, and `git grep` audits.

---

## Task 1: Rewrite the zig-common.sh sccache hand-off

**Files:**
- Modify: `scripts/zig-common.sh` (remove `zig_sccache_reexec` 46-62; rewrite `zig_main` tail 147-161)
- Verify: `shellcheck scripts/zig-common.sh scripts/zigcc scripts/zigc++`

- [ ] **Step 1: Write the failing verification harness**

This proves the NEW behavior: when `sccache` is on PATH, the wrapper must invoke it with `argv = [zig, cc, …, -target <T>, …]` (executable stem `zig`, `args[0]=cc`) — the exact shape sccache's `is_zig` + `zig_cc_subcommand` gate requires. We fake both `zig` and `sccache` so nothing actually compiles; the fake `sccache` just prints the argv it was handed.

Create `scripts/.tmp-zigcc-classify-test.sh`:

```bash
#!/bin/bash
# Throwaway: assert zigcc hands sccache `zig cc … -target …` (is_zig gate shape).
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Fake sccache: record argv (one per line) and exit 0 without running anything.
cat > "$tmp/sccache" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$SCCACHE_ARGV_OUT"
exit 0
EOF
chmod +x "$tmp/sccache"

# Fake zig on PATH so `zig version` (used nowhere now) / lookups don't escape.
cat > "$tmp/zig" <<'EOF'
#!/bin/bash
echo "0.0.0-test"
EOF
chmod +x "$tmp/zig"

export SCCACHE_ARGV_OUT="$tmp/argv"
export SCCACHE_PATH="$tmp/sccache"
export PATH="$tmp:$PATH"
export ZIG_TARGET="x86_64-linux-gnu.2.11"

# Invoke the real wrapper on a representative compile.
bash ./zigcc -c foo.c -o foo.o -Wall -O2

mapfile -t argv < "$tmp/argv"
echo "captured argv:"; printf '  [%s]\n' "${argv[@]}"

# Assertions: sccache saw `zig` as argv0-equivalent (first token) and `cc` next.
[ "${argv[0]}" = "zig" ] || { echo "FAIL: argv[0]=${argv[0]} (want zig)"; exit 1; }
[ "${argv[1]}" = "cc" ]  || { echo "FAIL: argv[1]=${argv[1]} (want cc)"; exit 1; }
printf '%s\n' "${argv[@]}" | grep -qx -- "-target" \
  || { echo "FAIL: -target absent (cross would break)"; exit 1; }
printf '%s\n' "${argv[@]}" | grep -qx -- "x86_64-linux-gnu.2.11" \
  || { echo "FAIL: target value absent"; exit 1; }
# -Wall must have been filtered out (GCC-only; clang/zig would warn).
printf '%s\n' "${argv[@]}" | grep -qx -- "-Wall" \
  && { echo "FAIL: -Wall leaked through (should be filtered)"; exit 1; }
# _ZIGCC_INNER must be GONE from the design (no self-reexec).
echo "PASS: sccache invoked as 'zig cc … -target …', -Wall filtered"
```

- [ ] **Step 2: Run it against the CURRENT wrapper to confirm it FAILS**

Run: `bash scripts/.tmp-zigcc-classify-test.sh`
Expected: **FAIL** — the current wrapper re-execs as `sccache "$0"` (where `$0`=`./zigcc`), so `argv[0]` is the wrapper path, not `zig`, and `argv[1]` is not `cc`. You'll see `FAIL: argv[0]=… (want zig)`.

- [ ] **Step 3: Remove `zig_sccache_reexec` and the cache-buster**

Delete the entire `zig_sccache_reexec` function (`scripts/zig-common.sh:38-62`, the comment block + function). Also delete its call site in `zig_main` (the `zig_sccache_reexec "$@"` line, currently line 155).

- [ ] **Step 4: Rewrite the `zig_main` tail to hand off to `sccache zig <mode>`**

Replace the final lines of `zig_main` — currently:

```bash
    zig_handle_dumpmachine "$@"    # gcc-compatible -dumpmachine (exits 0)
    zig_sccache_reexec "$@"        # outer role re-execs under sccache; inner falls through
    zig_filter_args "$@"           # sets ZIG_ARGS (filtered), ZIG_IS_COMPILE

    local xflag=()
    [ "$mode" = c++ ] && $ZIG_IS_COMPILE && xflag=(-x c++)
    exec zig "$mode" "${xflag[@]}" -target "$ZIG_CC_TARGET" "${ZIG_ARGS[@]}" "${ZIG_WNO[@]}"
```

with:

```bash
    zig_handle_dumpmachine "$@"    # gcc-compatible -dumpmachine (exits 0), BEFORE sccache:
                                   # sccache/clang would reject the versioned triple or run `zig -E`.
    zig_filter_args "$@"           # sets ZIG_ARGS (filtered), ZIG_IS_COMPILE

    local xflag=()
    [ "$mode" = c++ ] && $ZIG_IS_COMPILE && xflag=(-x c++)

    # Hand the real compile to `sccache zig <mode> …` so sccache sees the executable
    # stem `zig` and a `cc`/`c++` subcommand as argv[0] — the only shape that trips
    # sccache's is_zig gate (compiler.rs:1497) into the Zig toolchain packager and
    # thus DISTRIBUTES the TU across the farm. The wrapper still owns everything sccache
    # can't see through: -dumpmachine (above), GCC-only -W filtering, the -target
    # injection (rides through rewrite_dist_arguments to the worker), and the c++ `-x c++`.
    # No cache-buster needed: sccache now hashes the real `zig` binary + the visible
    # -target, so the (zig version, target) cache dimensions are captured natively.
    local _sccache="${SCCACHE_PATH:-}"
    [ -z "$_sccache" ] && _sccache="$(command -v sccache 2>/dev/null || true)"
    if [ -n "$_sccache" ]; then
        exec "$_sccache" zig "$mode" "${xflag[@]}" -target "$ZIG_CC_TARGET" "${ZIG_ARGS[@]}" "${ZIG_WNO[@]}"
    else
        # No sccache (local dev): compile directly — caching/distribution are opt-in.
        exec zig "$mode" "${xflag[@]}" -target "$ZIG_CC_TARGET" "${ZIG_ARGS[@]}" "${ZIG_WNO[@]}"
    fi
```

- [ ] **Step 5: Run the harness to verify it now PASSES**

Run: `bash scripts/.tmp-zigcc-classify-test.sh`
Expected: **PASS: sccache invoked as 'zig cc … -target …', -Wall filtered**

- [ ] **Step 6: Confirm the no-sccache fallback still drives zig directly**

Run (no SCCACHE_PATH, no sccache on PATH — point PATH at the fake zig only):
```bash
tmp=$(mktemp -d); printf '#!/bin/bash\necho "zig $*"\n' > "$tmp/zig"; chmod +x "$tmp/zig"
env -u SCCACHE_PATH PATH="$tmp:/usr/bin:/bin" ZIG_TARGET=x86_64-linux-gnu.2.11 \
    bash scripts/zigcc -c foo.c -o foo.o -Wall; rm -rf "$tmp"
```
Expected: a line `zig cc -c foo.c -o foo.o -O2 …  -target x86_64-linux-gnu.2.11 …` (no `-Wall`, no sccache) — proving the `else` branch execs `zig` directly.

(Note: `-O2` isn't in the test invocation; expect the flags you passed minus `-Wall`, plus `-target` and the ZIG_WNO set. The key check is `zig cc …` with no sccache prefix.)

- [ ] **Step 7: shellcheck the wrapper + shims**

Run: `shellcheck scripts/zig-common.sh scripts/zigcc scripts/zigc++ scripts/zigcc-native scripts/zigc++-native`
Expected: no new errors. (Pre-existing informational notes, if any, are unchanged — compare to `git stash` baseline only if a hard error appears.)

- [ ] **Step 8: Audit that the old mechanism is fully gone**

Run: `git grep -n "zig_sccache_reexec\|_ZIGCC_INNER\|SCCACHE_C_CUSTOM_CACHE_BUSTER" scripts/`
Expected: **no output** (rc=1). Every reference to the self-re-exec and the cache-buster is removed.

- [ ] **Step 9: Refresh the now-stale comments in the thin shims**

In `scripts/zigcc` and `scripts/zigc++`, the header comment claims the file is sourced "so $0 stays this script — sccache probes the wrapped compiler via $0". That rationale is obsolete (sccache now probes the real `zig`, not `$0`). Replace that clause in BOTH files' comments with: "It is SOURCED (not exec'd) so the C++/cc mode and arg-filtering run in this process before the wrapper hands the real compile to `sccache zig <mode>` (see zig-common.sh)." Keep the "not a symlink" sentence (still true: two shims pass distinct modes). No code line changes.

- [ ] **Step 10: Delete the throwaway harness and commit**

```bash
rm -f scripts/.tmp-zigcc-classify-test.sh
git add scripts/zig-common.sh scripts/zigcc scripts/zigc++
git commit -m "fix(zig): hand compiles to 'sccache zig cc' so TUs distribute

The wrapper re-execed as 'sccache <self>', which sccache classifies as a
generic clang-ish cc -> the Zig toolchain is never packaged and every TU
compiles locally (farm idle). Hand off to 'sccache zig <mode>' instead so
sccache's is_zig gate fires (executable stem 'zig', argv[0] cc/c++) and the
ZigToolchainPackager ships zig+lib -> TUs distribute. -target rides through
to the worker untouched. Drop SCCACHE_C_CUSTOM_CACHE_BUSTER: sccache now
hashes the real zig binary + the visible -target, so the (version,target)
cache dimensions are captured natively. Keep the no-sccache local-dev
fallback (exec zig directly).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add the 15-worker job to build.yml

**Files:**
- Modify: `.github/workflows/build.yml` (add a `workers` job after `build-prep-image`)
- Verify: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml'))"`

- [ ] **Step 1: Add the `workers` job**

Insert this job immediately after the `build-prep-image` job's closing (before the old `cell:` job). It does NOT need the prep image — bare `ubuntu-latest` + the dist-action's bundled engine + the runner's preinstalled Docker:

```yaml
  # ---------------------------------------------------------------------------
  # Workers: 15 ephemeral sccache-dist servers forming ONE farm for this run.
  # Plain ubuntu-latest (Docker preinstalled) — the zig toolchain travels in the
  # dist toolchain-archive, so no prep image is needed here. Each worker binds to
  # this run's single coordinator (run-prefix = github.run_id) and self-tears-down
  # when the coordinator (the build job) exits.
  # ---------------------------------------------------------------------------
  workers:
    needs: build-prep-image
    runs-on: ubuntu-latest
    timeout-minutes: 180
    strategy:
      fail-fast: false
      matrix:
        idx: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    steps:
      - name: Run sccache-dist worker ${{ matrix.idx }}
        uses: xdqi/sccache-dist-action@v0.0.4
        with:
          mode: worker
          worker-index: ${{ matrix.idx }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci
```

- [ ] **Step 2: YAML-parse the file**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('yaml ok')"`
Expected: `yaml ok` (no parse error). The file still has the old `cell`/`collect-*` jobs at this point — that's fine; they're removed in Task 3.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add 15-worker sccache-dist farm job

15 ubuntu-latest workers (mode: worker) form one farm per run, bound to the
coordinator via run-prefix=github.run_id. Needs the TS_OAUTH_SECRET repo
secret (tag:ci tagOwner). The cell/collect jobs are replaced in the next
commit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Replace cell + collect-* with the single coordinator `build` job

**Files:**
- Modify: `.github/workflows/build.yml` (delete `cell`, `collect-linux`, `collect-darwin`; add `build`)
- Verify: YAML parse + a structural grep audit

- [ ] **Step 1: Delete the three old jobs**

Remove the entire `cell:` job, the entire `collect-linux:` job, and the entire `collect-darwin:` job from `.github/workflows/build.yml`. (Everything from `  cell:` through the end of `collect-darwin:` — they are the last three jobs in the file.)

- [ ] **Step 2: Add the single `build` coordinator job**

Append this `build` job (it becomes the last job). It runs in the prep image (has zig + sysroots + git + github-cli), starts the coordinator, configures the S3 cache AFTER the coordinator step, builds linux phases with `MAKEFLAGS=-j$SCCACHE_J`, assembles + releases linux, then on push does darwin back-to-back. The assemble/release step bodies are lifted verbatim from the old `collect-linux`/`collect-darwin` jobs.

```yaml
  # ---------------------------------------------------------------------------
  # Build (single client/coordinator container): drives the 15-worker farm.
  # Replaces the 12-cell fan-out + the two collect jobs. Builds all linux phases
  # serially (TUs fan out to the farm via MAKEFLAGS=-j$SCCACHE_J), assembles +
  # releases linux; then on push builds darwin back-to-back (same farm, same S3
  # cache) and releases it. A SECOND coordinator can't share one worker pool
  # (workers hard-bind to one coordinator), so darwin is sequential here, not a
  # separate client.
  # ---------------------------------------------------------------------------
  build:
    needs: [build-prep-image, workers]
    runs-on: ubuntu-latest
    timeout-minutes: 360
    container:
      image: ${{ needs.build-prep-image.outputs.image }}
    steps:
      - name: Start sccache-dist coordinator (15-worker farm)
        id: farm
        uses: xdqi/sccache-dist-action@v0.0.4
        with:
          mode: coordinator
          expected-workers: 15
          min-workers: 8
          wait-timeout: 600s
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      # AFTER the coordinator step so the S3 client cache wins over the coordinator's
      # local SCCACHE_DIR. Same SeaweedFS bucket the 12 cells used (verified reachable).
      # MAKEFLAGS=-j$SCCACHE_J is THE knob that fans each package's TUs to the farm:
      # makepkg reads -j from MAKEFLAGS, which is otherwise unset (packages would
      # compile serially). runuser preserves exported env, so it reaches makepkg.
      - name: Configure sccache S3 cache + farm -j
        env:
          SCCACHE_BUCKET: ${{ secrets.SCCACHE_S3_BUCKET }}
          SCCACHE_ENDPOINT: ${{ secrets.SCCACHE_S3_ENDPOINT }}
          AWS_ACCESS_KEY_ID: ${{ secrets.SCCACHE_S3_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.SCCACHE_S3_SECRET }}
        run: |
          {
            echo "SCCACHE_REGION=auto"
            echo "SCCACHE_S3_USE_SSL=true"
            echo "SCCACHE_S3_KEY_PREFIX=msys2-cross"
            echo "SCCACHE_IDLE_TIMEOUT=0"
            echo "SCCACHE_BUCKET=${SCCACHE_BUCKET}"
            echo "SCCACHE_ENDPOINT=${SCCACHE_ENDPOINT}"
            echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
            echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
            echo "MAKEFLAGS=-j${SCCACHE_J:-2}"
          } >> "$GITHUB_ENV"
          if [ -z "${SCCACHE_BUCKET}" ]; then
            echo "::warning::SCCACHE_S3_* secrets absent — sccache S3 cache disabled (farm still distributes)."
          fi
          echo "Farm: SCCACHE_J=${SCCACHE_J} workers=${SCCACHE_WORKERS_ONLINE}"

      - name: Build linux phases via the farm
        working-directory: /opt/msys-cross
        run: |
          set -euo pipefail
          for ph in others chain:mingw64 chain:mingw32 chain:ucrt64 chain:cygwin clang; do
            echo "::group::build linux $ph"
            bash scripts/build.sh linux "$ph"
            echo "::endgroup::"
          done

      - name: sccache stats (linux)
        if: always()
        run: "${SCCACHE_PATH:-sccache} --show-stats || true"

      - name: Assemble linux repo db + installer
        working-directory: /opt/msys-cross
        run: bash scripts/build.sh linux assemble

      - name: Summarize linux repo
        working-directory: /opt/msys-cross
        run: |
          echo "=== Packages ==="; ls -lh repo/*.pkg.tar.* 2>/dev/null || true
          echo "=== Database ==="; ls -lh repo/msys-cross.db* repo/msys-cross.files* 2>/dev/null || true
          echo "=== Bootstrap ==="; ls -lh repo/bootstrap.tar.xz 2>/dev/null || true

      - name: Upload linux pacman repo
        uses: actions/upload-artifact@v7
        with:
          name: msys-cross-repo
          path: |
            /opt/msys-cross/repo/*.pkg.tar.*
            /opt/msys-cross/repo/msys-cross.db*
            /opt/msys-cross/repo/msys-cross.files*
          if-no-files-found: error
          retention-days: 14

      - name: Upload linux bootstrap tarball
        uses: actions/upload-artifact@v7
        with:
          name: msys-cross-bootstrap
          path: /opt/msys-cross/repo/bootstrap.tar.xz
          if-no-files-found: error
          retention-days: 14

      - name: Publish linux release
        if: github.event_name == 'push'
        working-directory: /opt/msys-cross
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          set -euo pipefail
          date_tag="$(date -u +%Y%m%d)"
          n="$(gh release list --limit 200 --json tagName \
                 --jq "[.[] | select(.tagName | startswith(\"build-${date_tag}.\"))] | length" \
               2>/dev/null || echo 0)"
          tag="build-${date_tag}.$((n + 1))"
          echo "Release tag: $tag"
          assets=()
          for f in repo/*.pkg.tar.* repo/msys-cross.db.tar.gz repo/msys-cross.files.tar.gz repo/bootstrap.tar.xz; do
            [ -f "$f" ] && assets+=("$f")
          done
          echo "Uploading ${#assets[@]} assets"
          gh release create "$tag" "${assets[@]}" \
            --title "$tag" \
            --notes "Automated build from ${GITHUB_SHA}. Consumed by msys-mirror; pin via /archive/${tag}/." \
            --target "${GITHUB_SHA}"

      # ---- darwin: push-only, back-to-back in the SAME coordinator container ----
      - name: Build darwin phases via the farm
        if: github.event_name == 'push'
        working-directory: /opt/msys-cross
        run: |
          set -euo pipefail
          for ph in others chain:mingw64 chain:mingw32 chain:ucrt64 chain:cygwin clang; do
            echo "::group::build darwin $ph"
            bash scripts/build.sh darwin "$ph"
            echo "::endgroup::"
          done

      - name: sccache stats (darwin)
        if: ${{ always() && github.event_name == 'push' }}
        run: "${SCCACHE_PATH:-sccache} --show-stats || true"

      - name: Assemble darwin repo db + installer
        if: github.event_name == 'push'
        working-directory: /opt/msys-cross
        run: bash scripts/build.sh darwin assemble

      - name: Upload darwin pacman repo
        if: github.event_name == 'push'
        uses: actions/upload-artifact@v7
        with:
          name: msys-cross-darwin-repo
          path: |
            /opt/msys-cross/repo-darwin/*.pkg.tar.*
            /opt/msys-cross/repo-darwin/msys-cross-darwin.db*
            /opt/msys-cross/repo-darwin/msys-cross-darwin.files*
            /opt/msys-cross/repo-darwin/bootstrap-darwin.tar.xz
          if-no-files-found: error
          retention-days: 14

      - name: Publish darwin release
        if: github.event_name == 'push'
        working-directory: /opt/msys-cross
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          set -euo pipefail
          date_tag="$(date -u +%Y%m%d)"
          n="$(gh release list --limit 200 --json tagName \
                 --jq "[.[] | select(.tagName | startswith(\"build-darwin-${date_tag}.\"))] | length" \
               2>/dev/null || echo 0)"
          tag="build-darwin-${date_tag}.$((n + 1))"
          echo "Release tag: $tag"
          assets=()
          for f in repo-darwin/*.pkg.tar.* repo-darwin/msys-cross-darwin.db.tar.gz repo-darwin/msys-cross-darwin.files.tar.gz repo-darwin/bootstrap-darwin.tar.xz; do
            [ -f "$f" ] && assets+=("$f")
          done
          echo "Uploading ${#assets[@]} assets"
          gh release create "$tag" "${assets[@]}" \
            --title "$tag" \
            --notes "Automated darwin (arm64 macOS host) build from ${GITHUB_SHA}." \
            --target "${GITHUB_SHA}"
```

- [ ] **Step 3: YAML-parse the file**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/build.yml')); print('jobs:', sorted(d['jobs']))"`
Expected: `jobs: ['build', 'build-prep-image', 'workers']` — exactly three jobs, no `cell`/`collect-linux`/`collect-darwin`.

- [ ] **Step 4: Structural audit**

Run:
```bash
grep -c "uses: xdqi/sccache-dist-action@v0.0.4" .github/workflows/build.yml   # expect 2 (worker + coord)
grep -n "mode: worker\|mode: coordinator\|expected-workers: 15\|MAKEFLAGS=-j" .github/workflows/build.yml
git grep -n "mozilla-actions/sccache-action\|SCCACHE_PATH=\|matrix:\s*$" .github/workflows/build.yml || true
```
Expected: the dist-action appears exactly twice; one `mode: worker`, one `mode: coordinator`, `expected-workers: 15`, and the `MAKEFLAGS=-j` line are present; the old `mozilla-actions/sccache-action` and the per-cell `SCCACHE_PATH=` export are **gone** (the dist-action provides sccache).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: replace 12 cells + 2 collect jobs with one coordinator build job

Single client container drives the 15-worker farm: builds all linux phases
with MAKEFLAGS=-j\$SCCACHE_J (TUs distribute), assembles + releases linux,
then on push builds darwin back-to-back (same farm + S3 cache) and releases
it. S3 cache configured AFTER the coordinator step so it wins over the local
SCCACHE_DIR. Darwin can't be a second coordinator (workers bind to one), so
it's sequential. Known trade-off: package compression/assembly is now
single-container (~dual-core) vs spread across 12 cells.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Final consistency check of the workflow

**Files:**
- Verify only: `.github/workflows/build.yml`

- [ ] **Step 1: Confirm `permissions` still cover the inline release**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/build.yml')); print(d.get('permissions'))"`
Expected: `{'contents': 'write', 'packages': 'write'}` — `contents: write` is needed for `gh release create` (now done inside `build`, previously in `collect-*`). Unchanged from before. If absent, add it.

- [ ] **Step 2: Confirm `needs` wiring is acyclic and complete**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/build.yml')); print({k:(v.get('needs')) for k,v in d['jobs'].items()})"`
Expected: `{'build-prep-image': None, 'workers': 'build-prep-image', 'build': ['build-prep-image', 'workers']}` — `build` waits for both the image and the worker fleet to be up.

- [ ] **Step 3: Confirm concurrency cancel still present**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/build.yml')); print(d.get('concurrency'))"`
Expected: `{'group': 'build-${{ github.ref }}', 'cancel-in-progress': True}`. (When a run is cancelled, the coordinator job dies → workers observe the coordinator offline and self-tear-down. No orphaned farm.)

- [ ] **Step 4: Commit (only if Steps 1-3 required an edit)**

```bash
git add .github/workflows/build.yml
git commit -m "ci: keep contents:write + needs wiring for inline release"
```
(Skip if nothing changed — the prior commits already satisfy all three checks.)

---

## Self-Review Notes (addressed)

- **Spec coverage:** 15 workers (Task 2) ✓; single client container (Task 3) ✓; same S3 endpoint, set after coordinator (Task 3 Step 2) ✓; `zig-common.sh` → `sccache zig cc` (Task 1) ✓; cache-buster removed (Task 1 Step 3/8) ✓; darwin same coordinator push-only (Task 3) ✓; `MAKEFLAGS=-j$SCCACHE_J` saturation (Task 3 Step 2) ✓; prep image + build.sh phases unchanged ✓; `TS_OAUTH_SECRET` prereq noted (Task 2 commit + below).
- **Compression trade-off:** documented in the spec and the Task 3 commit message; no code change (out of scope).
- **Type/name consistency:** `SCCACHE_J` (exported by the coordinator action), `MAKEFLAGS`, `run-prefix=github.run_id` (default), phase names (`others chain:mingw64 chain:mingw32 chain:ucrt64 chain:cygwin clang`) all match `scripts/build.sh`'s accepted phases and the action's outputs.

## Out-of-band prerequisite (NOT a code task — confirm before first run)

`TS_OAUTH_SECRET` must exist as a repo secret on the msys2-cross repo, with a `tag:ci` tagOwner in the tailnet ACL (same secret sccache-dist-action's own smoke workflow uses). Set via `gh secret set TS_OAUTH_SECRET --repo <owner>/msys2-cross`. Without it both worker and coordinator fail at tsnet join. The `SCCACHE_S3_*` secrets are already set (verified reachable this session).
