# Zig old-glibc aligned-new patch (GNU patch) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make zig cross-compile C++17 aligned `new`/`delete` for old glibc (<2.16) with no zig rebuild, no compat object, and no extra `-D` flags — by applying pre-generated unified diffs to zig's bundled libc++ headers at install time.

**Architecture:** Three committed unified diffs under `scripts/zig-patches/` encode the libc++ edits (one `__config` diff per zig era, plus a backend-`#elif` diff for the 0.17-dev era). A thin wrapper `scripts/patch_zig_libcxx_oldglibc.sh` detects the era, applies the right diffs with `patch -N -p1 --fuzz=3`, then self-verifies by compiling an aligned-new probe (must link, use `posix_memalign`, stay ≤ glibc 2.11; 2.17 must still use `aligned_alloc`). It is invoked from `prepare-zig.sh` after the `build/zig` symlink. A Docker harness verifies the whole thing against fresh upstream tarballs.

**Tech Stack:** Bash, GNU `patch`/`diff`, zig (`zig c++`), `objdump`, Docker.

**Spec:** `docs/superpowers/specs/2026-06-03-zig-oldglibc-aligned-new-design.md`

---

## File Structure

All paths relative to `/home/kosaka/msys2-cross`.

- **Create** `scripts/zig-patches/config-0.16.0.patch` — `__config` override for the 0.16.0 era.
- **Create** `scripts/zig-patches/config-0.17-dev.patch` — `__config` override for the 0.17-dev era.
- **Create** `scripts/zig-patches/aligned_alloc-0.17-dev.patch` — backend `#elif` guards for the 0.17-dev era (two files in one diff).
- **Create** `scripts/patch_zig_libcxx_oldglibc.sh` — wrapper: locate zig, detect era, apply diffs, self-verify.
- **Create** `scripts/test-zig-oldglibc-patch.sh` — Docker harness verifying against fresh upstream tarballs.
- **Modify** `scripts/prepare-zig.sh` — call the wrapper after the `build/zig` symlink line.

Diffs are relative to the libc++ root and applied with `-p1 -d "$LIBCXX"` where `LIBCXX=<zig-prefix>/lib/libcxx`.

## Environment constraints (apply to every task)

- The repo is on branch `worktree-pacman-from-source` with UNRELATED uncommitted pacman/clang changes. NEVER stage or commit those. Each `git add` names only the exact file(s) for that task. Stay on this branch; do not switch/create branches.
- Do NOT modify any `/opt/zig-*` install. Tests copy a zig tree to a ROOT-disk temp dir — use `mktemp -d -p /home/kosaka` (NOT the default `/tmp`, which is a ~2G tmpfs too small for a ~400MB zig copy + build cache).
- Test installs available: `/opt/zig-x86_64-linux-0.16.0` (0.16.0 era), `/opt/zig-x86_64-linux-0.17.0-dev.657+2faf8debf` (0.17-dev era).

---

## Task 1: Commit the three patch files

**Files:**
- Create: `scripts/zig-patches/config-0.16.0.patch`
- Create: `scripts/zig-patches/config-0.17-dev.patch`
- Create: `scripts/zig-patches/aligned_alloc-0.17-dev.patch`

These are the verified diffs (already proven to apply to pristine trees and produce a working `posix_memalign` build). Create each file with EXACTLY the content shown — trailing newline included, no timestamp lines on the `---`/`+++` headers.

- [ ] **Step 1: Create `scripts/zig-patches/config-0.16.0.patch`**

```
--- a/include/__config
+++ b/include/__config
@@ -697,6 +697,16 @@
 #    define _LIBCPP_HAS_C11_ALIGNED_ALLOC 1
 #  endif
 
+// anyfs override: re-enable C++17 aligned new/delete on glibc < 2.16
+#if defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16))
+#  undef  _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION
+#  define _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION 1
+#  undef  _LIBCPP_HAS_ALIGNED_ALLOCATION
+#  define _LIBCPP_HAS_ALIGNED_ALLOCATION 1
+#  undef  _LIBCPP_HAS_C11_ALIGNED_ALLOC
+#  define _LIBCPP_HAS_C11_ALIGNED_ALLOC 0
+#endif
+
 #  if defined(__APPLE__) || defined(__FreeBSD__)
 #    define _LIBCPP_WCTYPE_IS_MASK
 #  endif
```

- [ ] **Step 2: Create `scripts/zig-patches/config-0.17-dev.patch`**

```
--- a/include/__config
+++ b/include/__config
@@ -488,6 +488,14 @@
 #    endif
 #  endif
 
+// anyfs override: re-enable C++17 aligned new/delete on glibc < 2.16
+#if defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16))
+#  undef  _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION
+#  define _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION 1
+#  undef  _LIBCPP_HAS_ALIGNED_ALLOCATION
+#  define _LIBCPP_HAS_ALIGNED_ALLOCATION 1
+#endif
+
 #  if defined(__APPLE__) || defined(__FreeBSD__)
 #    define _LIBCPP_WCTYPE_IS_MASK
 #  endif
```

- [ ] **Step 3: Create `scripts/zig-patches/aligned_alloc-0.17-dev.patch`**

```
--- a/include/__memory/aligned_alloc.h
+++ b/include/__memory/aligned_alloc.h
@@ -29,7 +29,7 @@
 inline _LIBCPP_HIDE_FROM_ABI void* __libcpp_aligned_alloc(std::size_t __alignment, std::size_t __size) {
 #  if defined(_LIBCPP_MSVCRT_LIKE)
   return ::_aligned_malloc(__size, __alignment);
-#  elif _LIBCPP_STD_VER >= 17 && _LIBCPP_HAS_C11_ALIGNED_ALLOC
+#  elif (_LIBCPP_STD_VER >= 17 && _LIBCPP_HAS_C11_ALIGNED_ALLOC) && !(defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16)))  // anyfs override: old-glibc -> posix_memalign
   // aligned_alloc() requires that __size is a multiple of __alignment,
   // but for C++ [new.delete.general], only states "if the value of an
   // alignment argument passed to any of these functions is not a valid
--- a/src/include/aligned_alloc.h
+++ b/src/include/aligned_alloc.h
@@ -31,7 +31,7 @@
   return ::_aligned_malloc(__size, __alignment);
 
 // Android only provides aligned_alloc when targeting API 28 or higher.
-#  elif !defined(__ANDROID__) || __ANDROID_API__ >= 28
+#  elif (!defined(__ANDROID__) || __ANDROID_API__ >= 28) && !(defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16)))  // anyfs override: old-glibc -> posix_memalign
   // aligned_alloc() requires that __size is a multiple of __alignment,
   // but for C++ [new.delete.general], only states "if the value of an
   // alignment argument passed to any of these functions is not a valid
```

- [ ] **Step 4: Verify all three apply cleanly to pristine copies**

Run (copies a tree to root-disk temp, dry-run applies, cleans up):
```bash
T=$(mktemp -d -p /home/kosaka)
cp -r /opt/zig-x86_64-linux-0.16.0/lib/libcxx "$T/cxx016"
cp -r /opt/zig-x86_64-linux-0.17.0-dev.657+2faf8debf/lib/libcxx "$T/cxx017"
echo "-- 0.16 config --"
patch -N -p1 --fuzz=3 -d "$T/cxx016" --dry-run < scripts/zig-patches/config-0.16.0.patch
echo "-- 0.17 config --"
patch -N -p1 --fuzz=3 -d "$T/cxx017" --dry-run < scripts/zig-patches/config-0.17-dev.patch
echo "-- 0.17 aligned_alloc --"
patch -N -p1 --fuzz=3 -d "$T/cxx017" --dry-run < scripts/zig-patches/aligned_alloc-0.17-dev.patch
rm -rf "$T"
```
Expected: each prints `checking file …` and reports the hunk(s) succeeding (no "FAILED"), exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/zig-patches/config-0.16.0.patch scripts/zig-patches/config-0.17-dev.patch scripts/zig-patches/aligned_alloc-0.17-dev.patch
git commit -m "feat(zig-patch): pre-generated libc++ diffs for old-glibc aligned-new"
```

---

## Task 2: Wrapper script — locate zig, detect era, apply diffs

**Files:**
- Create: `scripts/patch_zig_libcxx_oldglibc.sh`

- [ ] **Step 1: Write the wrapper script**

Create `scripts/patch_zig_libcxx_oldglibc.sh` with EXACTLY this content:

```bash
#!/bin/bash
# Patch a zig install's bundled libc++ so C++17 aligned new/delete links for
# old glibc (<2.16) targets — no zig rebuild, no compat object, no -D flags.
#
# Usage: patch_zig_libcxx_oldglibc.sh <zig-install-dir>
#        patch_zig_libcxx_oldglibc.sh --zig-prefix <zig-install-dir>
#
# Applies pre-generated diffs from scripts/zig-patches/ with `patch -N`
# (idempotent: re-running is a no-op). Then self-verifies and, on failure,
# restores from patch's .orig backups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/zig-patches"

die() { echo "patch_zig_libcxx_oldglibc: $*" >&2; exit 1; }

# ---- arg parsing ----
case "${1:-}" in
    --zig-prefix) ZIG_PREFIX="${2:?--zig-prefix needs a dir}" ;;
    "")           die "usage: $0 <zig-install-dir>" ;;
    *)            ZIG_PREFIX="$1" ;;
esac
[ -d "$ZIG_PREFIX" ] || die "not a directory: $ZIG_PREFIX"

ZIG_BIN="$ZIG_PREFIX/zig"
[ -x "$ZIG_BIN" ] || die "no zig binary at $ZIG_BIN"

LIBCXX="$ZIG_PREFIX/lib/libcxx"
[ -f "$LIBCXX/include/__config" ] || die "no libc++ __config under $LIBCXX"

# ---- era detection ----
if [ -f "$LIBCXX/src/include/aligned_alloc.h" ]; then
    ERA="0.17-dev"
    PATCHES=(config-0.17-dev.patch aligned_alloc-0.17-dev.patch)
else
    ERA="0.16.0"
    PATCHES=(config-0.16.0.patch)
fi
echo "patch_zig_libcxx_oldglibc: era=$ERA prefix=$ZIG_PREFIX"

# ---- apply ----
apply_one() {
    local pf="$PATCH_DIR/$1" out rc
    [ -f "$pf" ] || die "missing patch file: $pf"
    out="$(patch -N -p1 --fuzz=3 -d "$LIBCXX" < "$pf" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "patch_zig_libcxx_oldglibc: applied $1"
    elif printf '%s\n' "$out" | grep -qiE 'previously applied|Reversed'; then
        echo "patch_zig_libcxx_oldglibc: $1 already applied (skipping)"
    else
        printf '%s\n' "$out" >&2
        die "failed to apply $1 (see .rej under $LIBCXX)"
    fi
}
for p in "${PATCHES[@]}"; do apply_one "$p"; done

# (Task 3 appends self-verify below.)
```

- [ ] **Step 2: Make executable and smoke-test era detection + apply on COPIES**

Run:
```bash
chmod +x scripts/patch_zig_libcxx_oldglibc.sh
# 0.16 copy
T=$(mktemp -d -p /home/kosaka); cp -r /opt/zig-x86_64-linux-0.16.0 "$T/z"
scripts/patch_zig_libcxx_oldglibc.sh "$T/z"
grep -c 'anyfs override' "$T/z/lib/libcxx/include/__config"   # expect 1
# idempotency: second run is a no-op
scripts/patch_zig_libcxx_oldglibc.sh "$T/z"
grep -c 'anyfs override' "$T/z/lib/libcxx/include/__config"   # still 1
rm -rf "$T"
```
Expected: first run prints `era=0.16.0` and `applied config-0.16.0.patch`; marker count `1`. Second run prints `already applied (skipping)`; marker count still `1`.

Then 0.17 copy:
```bash
T=$(mktemp -d -p /home/kosaka); cp -r /opt/zig-x86_64-linux-0.17.0-dev.657+2faf8debf "$T/z"
scripts/patch_zig_libcxx_oldglibc.sh "$T/z"
grep -c 'anyfs override' "$T/z/lib/libcxx/include/__config" "$T/z/lib/libcxx/include/__memory/aligned_alloc.h" "$T/z/lib/libcxx/src/include/aligned_alloc.h"
rm -rf "$T"
```
Expected: prints `era=0.17-dev`, `applied config-0.17-dev.patch`, `applied aligned_alloc-0.17-dev.patch`; each of the three files shows marker count `1`.

Confirm `/opt` is untouched: `grep -L 'anyfs override' /opt/zig-x86_64-linux-0.16.0/lib/libcxx/include/__config` should list the file (i.e. it does NOT contain the marker).

- [ ] **Step 3: Commit**

```bash
git add scripts/patch_zig_libcxx_oldglibc.sh
git commit -m "feat(zig-patch): wrapper — era detection + patch apply (idempotent)"
```

---

## Task 3: Deterministic backups + self-verify (link probe) with rollback

**Files:**
- Modify: `scripts/patch_zig_libcxx_oldglibc.sh` — (a) make `apply_one` create an explicit backup before each apply; (b) replace the trailing `# (Task 3 appends self-verify below.)` comment with the self-verify + rollback + cleanup block.

**Why explicit backups:** GNU `patch` only writes a `.orig` backup when an apply is *non-clean* (uses fuzz/offset). On a clean apply against a pristine tree it writes **no** `.orig`, so a rollback that looks for `.orig` files silently restores nothing. We force a deterministic backup with `-b --suffix=.anyfsbak` so rollback always works, and we clean the backups (and any `.rej`) on success. (Verified: `patch -b --suffix=.anyfsbak` produces a backup even on a clean apply; restoring from it rolls back to a zero-marker pristine state.)

- [ ] **Step 1: Make `apply_one` create a deterministic backup**

In `scripts/patch_zig_libcxx_oldglibc.sh`, change the `patch` invocation inside `apply_one` to add `-b --suffix=.anyfsbak`. Replace this line:

```bash
    out="$(patch -N -p1 --fuzz=3 -d "$LIBCXX" < "$pf" 2>&1)" && rc=0 || rc=$?
```

with:

```bash
    out="$(patch -N -b --suffix=.anyfsbak -p1 --fuzz=3 -d "$LIBCXX" < "$pf" 2>&1)" && rc=0 || rc=$?
```

- [ ] **Step 2: Append the self-verify + rollback + cleanup block**

Replace the final line `# (Task 3 appends self-verify below.)` with:

```bash
# ---- self-verify (backstop against a fuzzed mis-apply) ----
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT
cat > "$PROBE_DIR/anew.cpp" <<'EOF'
#include <new>
#include <cstdint>
struct alignas(64) Big { char x[64]; };
int main() { Big* p = new Big(); int r = (int)((uintptr_t)p & 63); delete p; return r; }
EOF
export ZIG_GLOBAL_CACHE_DIR="$PROBE_DIR/zc"   # isolated cache -> real libc++ recompile

# Restore originals from our deterministic .anyfsbak backups, then remove any .rej.
restore_backups() {
    find "$LIBCXX" -name '*.anyfsbak' -print0 | while IFS= read -r -d '' b; do
        mv -f "$b" "${b%.anyfsbak}"
    done
    find "$LIBCXX" -name '*.rej' -delete
}

verify_target() {  # <triple> <want-symbol> <forbid-symbol>
    local triple="$1" want="$2" forbid="$3" out="$PROBE_DIR/probe.bin" syms
    if ! "$ZIG_BIN" c++ -target "$triple" -std=c++17 "$PROBE_DIR/anew.cpp" -o "$out" 2>"$PROBE_DIR/err"; then
        echo "  verify FAIL: $triple did not link" >&2
        grep -oE 'undefined symbol:[^>]*' "$PROBE_DIR/err" | sort -u >&2
        return 1
    fi
    syms="$(objdump -T "$out" 2>/dev/null | grep -oE 'aligned_alloc|posix_memalign' | sort -u | tr '\n' ',')"
    if [ -n "$want" ]   && ! printf '%s' "$syms" | grep -q "$want";   then echo "  verify FAIL: $triple missing $want (got [$syms])" >&2; return 1; fi
    if [ -n "$forbid" ] &&   printf '%s' "$syms" | grep -q "$forbid"; then echo "  verify FAIL: $triple uses forbidden $forbid (got [$syms])" >&2; return 1; fi
    echo "  verify OK: $triple -> [$syms]"
}

VERIFY_OK=1
verify_target x86_64-linux-gnu.2.11 posix_memalign aligned_alloc || VERIFY_OK=0
verify_target x86_64-linux-gnu.2.17 aligned_alloc ""             || VERIFY_OK=0

if [ "$VERIFY_OK" -ne 1 ]; then
    restore_backups
    die "self-verify failed; libc++ restored from backups"
fi

# success: drop our backups and any stray .rej (e.g. from an idempotent re-run)
find "$LIBCXX" \( -name '*.anyfsbak' -o -name '*.rej' \) -delete
echo "patch_zig_libcxx_oldglibc: OK (era=$ERA)"
```

- [ ] **Step 3: Full run on a COPY of 0.16.0 (end-to-end)**

Run:
```bash
T=$(mktemp -d -p /home/kosaka); cp -r /opt/zig-x86_64-linux-0.16.0 "$T/z"
scripts/patch_zig_libcxx_oldglibc.sh "$T/z"
echo "leftover backups/rej:"; find "$T/z/lib/libcxx" \( -name '*.anyfsbak' -o -name '*.rej' \)
rm -rf "$T"
```
Expected output ends with:
```
  verify OK: x86_64-linux-gnu.2.11 -> [posix_memalign,]
  verify OK: x86_64-linux-gnu.2.17 -> [aligned_alloc,]
patch_zig_libcxx_oldglibc: OK (era=0.16.0)
```
and `leftover backups/rej:` prints nothing.

- [ ] **Step 4: Idempotent re-run leaves no .rej litter**

Run (apply twice, confirm the second run also ends OK and leaves no `.rej`/backup):
```bash
T=$(mktemp -d -p /home/kosaka); cp -r /opt/zig-x86_64-linux-0.16.0 "$T/z"
scripts/patch_zig_libcxx_oldglibc.sh "$T/z" >/dev/null
scripts/patch_zig_libcxx_oldglibc.sh "$T/z"
echo "leftover after re-run:"; find "$T/z/lib/libcxx" \( -name '*.anyfsbak' -o -name '*.rej' \)
rm -rf "$T"
```
Expected: second run prints `already applied (skipping)` for the patch(es) then the two `verify OK` lines and `OK (era=0.16.0)`; `leftover after re-run:` prints nothing (the success-path cleanup removes the `.rej` that `patch -N` drops on a re-apply).

- [ ] **Step 5: Full run on a COPY of 0.17-dev (end-to-end)**

Run:
```bash
T=$(mktemp -d -p /home/kosaka); cp -r /opt/zig-x86_64-linux-0.17.0-dev.657+2faf8debf "$T/z"
scripts/patch_zig_libcxx_oldglibc.sh "$T/z"
rm -rf "$T"
```
Expected: same two `verify OK` lines and `OK (era=0.17-dev)`.

- [ ] **Step 6: Negative test — a broken patch must roll back and fail**

A bogus patch that applies but leaves the build broken must cause self-verify to fail and roll back to a pristine tree:
```bash
T=$(mktemp -d -p /home/kosaka); cp -r /opt/zig-x86_64-linux-0.16.0 "$T/z"
cp -r scripts/zig-patches "$T/badpatches"
cat > "$T/badpatches/config-0.16.0.patch" <<'PATCH'
--- a/include/__config
+++ b/include/__config
@@ -697,6 +697,9 @@
 #    define _LIBCPP_HAS_C11_ALIGNED_ALLOC 1
 #  endif
 
+#if defined(__GLIBC__) && (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16)
+#  define _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION 1  /* anyfs override: deliberately incomplete */
+#endif
 
 #  if defined(__APPLE__) || defined(__FreeBSD__)
 #    define _LIBCPP_WCTYPE_IS_MASK
PATCH
# Point the wrapper at the bad patch dir by rewriting PATCH_DIR in a temp copy:
sed "s#\$SCRIPT_DIR/zig-patches#$T/badpatches#" scripts/patch_zig_libcxx_oldglibc.sh > "$T/wrap.sh"
chmod +x "$T/wrap.sh"
"$T/wrap.sh" "$T/z"; echo "exit=$?"
echo "after failure, __config must be pristine (marker count 0):"
grep -c 'anyfs override' "$T/z/lib/libcxx/include/__config"
echo "no backups/rej left:"; find "$T/z/lib/libcxx" \( -name '*.anyfsbak' -o -name '*.rej' \)
rm -rf "$T"
```
Expected: prints `verify FAIL: x86_64-linux-gnu.2.11 …` then `self-verify failed; libc++ restored from backups`, exits non-zero; marker count `0` (rolled back); no `.anyfsbak`/`.rej` remain.

- [ ] **Step 7: Commit**

```bash
git add scripts/patch_zig_libcxx_oldglibc.sh
git commit -m "feat(zig-patch): self-verify link probe with deterministic-backup rollback"
```

---

## Task 4: Wire into prepare-zig.sh

**Files:**
- Modify: `scripts/prepare-zig.sh` (after the `ln -sfn … build/zig` line)

- [ ] **Step 1: Add the patch call after the symlink line**

In `scripts/prepare-zig.sh`, the line `ln -sfn "zig-x86_64-linux-$ZIG_VER" "$PROJECT_ROOT/build/zig"` is followed by an `echo "Zig $ZIG_VER ready:"` block. Insert BETWEEN them (after the `ln -sfn …` line, before `echo "Zig $ZIG_VER ready:"`):

```bash

# Patch bundled libc++ so C++17 aligned new/delete links for old-glibc targets
# (idempotent + self-verifying). See scripts/patch_zig_libcxx_oldglibc.sh.
"$SCRIPTS_DIR/patch_zig_libcxx_oldglibc.sh" "$ZIG_INSTALL_DIR"
```

(`SCRIPTS_DIR` is defined at line 8 and `ZIG_INSTALL_DIR` at line 18 of `prepare-zig.sh`.)

- [ ] **Step 2: Syntax-check and exercise the tail flow on a throwaway copy**

Run:
```bash
bash -n scripts/prepare-zig.sh
# simulate prepare-zig's tail (symlink already done) against a copy:
T=$(mktemp -d -p /home/kosaka); cp -r /opt/zig-x86_64-linux-0.16.0 "$T/z"
SCRIPTS_DIR="$(pwd)/scripts" ZIG_INSTALL_DIR="$T/z" \
  bash -c '"$SCRIPTS_DIR/patch_zig_libcxx_oldglibc.sh" "$ZIG_INSTALL_DIR"'
rm -rf "$T"
```
Expected: `bash -n` is silent; the simulated call ends with `OK (era=0.16.0)`.

- [ ] **Step 3: Commit**

```bash
git add scripts/prepare-zig.sh
git commit -m "feat(prepare-zig): patch libc++ for old-glibc aligned-new at install"
```

---

## Task 5: Container test harness (fresh tarballs, both eras, aarch64, idempotency)

**Files:**
- Create: `scripts/test-zig-oldglibc-patch.sh`

- [ ] **Step 1: Write the harness**

Create `scripts/test-zig-oldglibc-patch.sh` with EXACTLY this content:

```bash
#!/bin/bash
# Containerized verification of patch_zig_libcxx_oldglibc.sh against PRISTINE
# upstream zig tarballs. Run on the host; spins a throwaway Docker container.
#
# Usage: bash scripts/test-zig-oldglibc-patch.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ZIG_TAGGED="0.16.0"
ZIG_DEV="0.17.0-dev.657+2faf8debf"   # pinned; harness falls back to current master if 404
IMAGE="debian:bookworm-slim"

docker run --rm \
    -v "$SCRIPT_DIR/patch_zig_libcxx_oldglibc.sh:/work/scripts/patch_zig_libcxx_oldglibc.sh:ro" \
    -v "$SCRIPT_DIR/zig-patches:/work/scripts/zig-patches:ro" \
    -e ZIG_TAGGED="$ZIG_TAGGED" -e ZIG_DEV="$ZIG_DEV" \
    "$IMAGE" bash -euo pipefail -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl xz-utils binutils patch python3 ca-certificates >/dev/null

        fetch() {  # <version> ; echoes extracted dir under /work
            local ver="$1" dir="zig-x86_64-linux-$ver" url
            case "$ver" in
                *-dev.*) url="https://ziglang.org/builds/$dir.tar.xz" ;;
                *)       url="https://ziglang.org/download/$ver/$dir.tar.xz" ;;
            esac
            cd /work
            if ! curl -fsSLO "$url"; then
                if [ "${ver#*-dev.}" != "$ver" ]; then
                    echo "pinned dev $ver gone; using current master" >&2
                    local j; j="$(curl -fsSL https://ziglang.org/download/index.json)"
                    url="$(echo "$j" | python3 -c "import sys,json;print(json.load(sys.stdin)[\"master\"][\"x86_64-linux\"][\"tarball\"])")"
                    dir="$(basename "$url" .tar.xz)"
                    curl -fsSLO "$url"
                else
                    echo "FAIL: cannot download $url" >&2; exit 1
                fi
            fi
            tar xf "$dir.tar.xz"
            echo "/work/$dir"
        }

        check() {  # <triple> <want> <forbid> ; uses $ZIG
            local triple="$1" want="$2" forbid="$3" s
            "$ZIG" c++ -target "$triple" -std=c++17 /work/anew.cpp -o /work/out 2>/work/e || {
                echo "  FAIL link $triple"; grep -oE "undefined symbol:[^>]*" /work/e | sort -u; return 1; }
            s="$(objdump -T /work/out 2>/dev/null | grep -oE "aligned_alloc|posix_memalign" | sort -u | tr "\n" ,)"
            [ -z "$want" ]   || echo "$s" | grep -q "$want"   || { echo "  FAIL $triple missing $want [$s]"; return 1; }
            [ -z "$forbid" ] ||   ! echo "$s" | grep -q "$forbid" || { echo "  FAIL $triple has $forbid [$s]"; return 1; }
            echo "  OK $triple [$s]"
        }

        cat > /work/anew.cpp <<EOF
#include <new>
#include <cstdint>
struct alignas(64) Big { char x[64]; };
int main(){ Big*p=new Big(); int r=(int)((uintptr_t)p&63); delete p; return r; }
EOF

        # the wrapper expects scripts/zig-patches as a sibling; /work/scripts has both (mounted)
        for ver in "$ZIG_TAGGED" "$ZIG_DEV"; do
            echo "==== zig $ver ===="
            d="$(fetch "$ver")"
            ZIG="$d/zig"
            echo "-- before patch: 2.11 must FAIL to link --"
            if "$ZIG" c++ -target x86_64-linux-gnu.2.11 -std=c++17 /work/anew.cpp -o /work/out 2>/dev/null; then
                echo "  UNEXPECTED: 2.11 linked before patch"; exit 1
            else echo "  OK: fails as expected"; fi
            echo "-- apply patch (self-verifies) --"
            bash /work/scripts/patch_zig_libcxx_oldglibc.sh "$d"
            echo "-- independent re-checks --"
            check x86_64-linux-gnu.2.11 posix_memalign aligned_alloc
            check x86_64-linux-gnu.2.17 aligned_alloc ""
            check aarch64-linux-gnu.2.17 aligned_alloc ""   # aarch64 no-op (glibc floor 2.17)
            echo "-- idempotency: re-run is a no-op --"
            # Capture stdout fully before grepping: piping straight into `grep -q`
            # lets grep close the pipe on first match, which SIGPIPEs the still-running
            # patch script (self-verify keeps writing) -> exit 141 -> pipefail mis-reports
            # a working idempotent re-run as a failure.
            rerun_out="$(bash /work/scripts/patch_zig_libcxx_oldglibc.sh "$d")"
            echo "$rerun_out" | grep -q "already applied" \
                && echo "  OK idempotent" || { echo "  FAIL not idempotent"; echo "$rerun_out"; exit 1; }
        done
        echo "ALL ZIG OLD-GLIBC PATCH TESTS PASSED"
    '
```

- [ ] **Step 2: Make executable and run**

Run:
```bash
chmod +x scripts/test-zig-oldglibc-patch.sh
bash scripts/test-zig-oldglibc-patch.sh
```
Expected: for each of `0.16.0` and `0.17.0-dev.657…`, the before-patch link fails, then:
```
  OK x86_64-linux-gnu.2.11 [posix_memalign,]
  OK x86_64-linux-gnu.2.17 [aligned_alloc,]
  OK aarch64-linux-gnu.2.17 [aligned_alloc,]
  OK idempotent
```
ending with `ALL ZIG OLD-GLIBC PATCH TESTS PASSED`. (Needs network + Docker; downloads ~100 MB of zig per era.)

- [ ] **Step 3: Commit**

```bash
git add scripts/test-zig-oldglibc-patch.sh
git commit -m "test(zig-patch): containerized verification vs fresh upstream tarballs"
```

---

## Task 6: Document the script in the scripts area

**Files:**
- Check/Modify: a scripts index or README if one exists.

- [ ] **Step 1: Add a pointer if a README/index exists**

Run: `ls README* scripts/README* 2>/dev/null`
- If a README exists, add one bullet describing the script:
  `- scripts/patch_zig_libcxx_oldglibc.sh — applies scripts/zig-patches/*.patch so zig's libc++ supports C++17 aligned new/delete on old glibc (<2.16); called by prepare-zig.sh.`
- If none exists, skip (the script header comment + this plan are the documentation).

- [ ] **Step 2: Commit (only if a file changed)**

```bash
git add -A
git commit -m "docs(zig-patch): note patch script in scripts index" || echo "nothing to document"
```

---

## Self-Review Notes

- **Spec coverage:** pre-generated diffs in `scripts/zig-patches/` (Task 1); wrapper with era detection + `patch -N -p1 --fuzz=3` + "previously applied" idempotency + `die` on hard failure (Task 2); self-verify 2.11/2.17 with `.orig` rollback as the fuzz backstop (Task 3); prepare-zig integration after the symlink (Task 4); container test vs fresh 0.16.0 + pinned 0.17-dev.657 + aarch64 no-op + idempotency re-run + index.json fallback (Task 5). All spec sections map to a task.
- **No placeholders:** patch contents and both scripts are embedded verbatim; the negative-rollback test (Task 3 Step 4) uses a concrete bogus patch.
- **Name consistency:** `LIBCXX`, `ZIG_PREFIX`, `ZIG_BIN`, `PATCH_DIR`, `ERA`, `PATCHES`, `apply_one`, `verify_target`, `restore_orig`, env `ZIG_TAGGED`/`ZIG_DEV` are used consistently. Patch filenames `config-0.16.0.patch` / `config-0.17-dev.patch` / `aligned_alloc-0.17-dev.patch` match between Task 1 (creation) and Task 2 (the `PATCHES` arrays).
