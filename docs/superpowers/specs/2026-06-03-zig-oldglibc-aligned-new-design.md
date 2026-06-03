# Zig old-glibc aligned-new fix — design

Date: 2026-06-03

## Problem

Zig's bundled clang/libc++ cannot link C++17 aligned `operator new`/`operator delete`
(`std::align_val_t`) when cross-compiling for an **old glibc** target (e.g.
`x86_64-linux-gnu.2.11`). A bare build fails with:

```
ld.lld: error: undefined symbol: operator new(unsigned long, std::align_val_t)
ld.lld: error: undefined symbol: operator delete(void*, unsigned long, std::align_val_t)
```

Root cause: zig injects `-D_LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION=0` (via clang's
`<command line>` buffer, baked into the zig binary — it does **not** appear in `-###`/`-cc1`
argv) for glibc < 2.16, because libc++ historically tied the C++17 aligned operators to C11
`aligned_alloc()`, which only landed in glibc 2.16. Disabling that feature macro removes not
just the `aligned_alloc()` backend but the entire aligned operator new/delete family **and**
the `std::align_val_t` type. The alignment itself needs nothing newer than `posix_memalign()`
(glibc 2.1.91), so the operators are perfectly implementable on old glibc — libc++ just
declines to emit them.

## Goal & constraints (hard requirements)

Fix old-glibc aligned-new such that downstream code compiles and links with:

1. **No rebuild of zig** — the zig binary stays as-is.
2. **No extra compat object** (no `aligned_new_compat.o`).
3. **No extra compile flags** — user/build command lines stay bare (`zig c++ -target … file.cpp`).

The fix is a patch to zig's **on-disk libc++ headers/sources**. Zig recompiles libc++/libc++abi
per-target via its content-addressed cache, so editing these files is normal `zig c++` behavior,
not "rebuilding zig". (Verified: zig hashes both edited `.cpp` and included `.h` content into the
cache key, so a patched file is recompiled, not served stale.)

## Two zig generations behave differently

The required patch depends on the vendored libc++ version. The discriminator is whether
`lib/libcxx/src/include/aligned_alloc.h` (the libc++abi-private backend header) exists:

| | **0.16.0 era** (`src/include/aligned_alloc.h` ABSENT) | **0.17-dev era** (`src/include/aligned_alloc.h` PRESENT) |
|---|---|---|
| Backend selector | `#elif _LIBCPP_STD_VER>=17 && _LIBCPP_HAS_C11_ALIGNED_ALLOC` (a macro you can toggle) | `#elif !defined(__ANDROID__) \|\| __ANDROID_API__>=28` (Linux hard-wired to `aligned_alloc`, **no** macro to toggle) |
| Files to patch | 1: `__config` | 3: `__config` + both `aligned_alloc.h` copies |

The 0.17-dev change is an upstream libc++ refactor that removed `_LIBCPP_HAS_C11_ALIGNED_ALLOC`
from the backend decision (it now assumes "non-Android Linux always has `aligned_alloc`"), so
the backend cannot be steered by a macro alone — the `#elif` condition itself must be patched.

Note there are **two** `aligned_alloc.h` files in the 0.17-dev tree, intentionally out of sync:
- `lib/libcxx/include/__memory/aligned_alloc.h` — used by user TUs
- `lib/libcxx/src/include/aligned_alloc.h` — used when zig compiles libc++abi (this is where the
  surviving `aligned_alloc` reference in `libc++abi.a`'s `stdlib_new_delete.o` / `fallback_malloc.o`
  comes from). **Both** must be patched, or `undefined symbol: aligned_alloc` survives in the
  archive even after the user-side header is fixed.

## Approach

Pre-generated **unified diffs** applied with GNU `patch`, driven by a small wrapper script
`scripts/patch_zig_libcxx_oldglibc.sh`. The diffs live in `scripts/zig-patches/` and are committed
to the repo, so a reviewer reads the change directly as a diff and the wrapper stays trivial. Using
`patch` (rather than a hand-rolled text-insertion engine) buys context-based hunk matching: a small
zig point-release that shifts line numbers but not the surrounding lines still applies (verified:
a hunk applied cleanly after a +200-line offset), and `patch -N` (`--forward`) gives idempotency for
free (a second apply reports "previously applied" and is skipped).

All edits are gated on `__GLIBC__ < 2.16` so **new-glibc targets are untouched** (verified: 2.17
still resolves to `aligned_alloc`, byte-for-byte unchanged behavior). `__GLIBC__`/`__GLIBC_MINOR__`
are visible at the `__config` patch site (libc++ transitively includes `<features.h>`; confirmed by
probe).

### The diffs

Three diff files, all relative to the libc++ root (`<prefix>/lib/libcxx`), applied with `-p1`:

- `scripts/zig-patches/config-0.16.0.patch` — Patch A for the 0.16.0 era (`include/__config`).
- `scripts/zig-patches/config-0.17-dev.patch` — Patch A for the 0.17-dev era (`include/__config`).
- `scripts/zig-patches/aligned_alloc-0.17-dev.patch` — Patch B for the 0.17-dev era (touches both
  `include/__memory/aligned_alloc.h` and `src/include/aligned_alloc.h`).

**Patch A — `__config` override (both eras).** Re-enables the library aligned-allocation feature
for old glibc, undoing zig's injected `=0`, and forces the `posix_memalign` backend:

```c
// anyfs override: re-enable C++17 aligned new/delete on glibc < 2.16
#if defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16))
#  undef  _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION
#  define _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION 1
#  undef  _LIBCPP_HAS_ALIGNED_ALLOCATION
#  define _LIBCPP_HAS_ALIGNED_ALLOCATION 1
#  undef  _LIBCPP_HAS_C11_ALIGNED_ALLOC      /* 0.16.0 era: steer backend to posix_memalign */
#  define _LIBCPP_HAS_C11_ALIGNED_ALLOC 0
#endif
```

**The block's position in `__config` differs by era** — it must land *after* every default
`#define` of the macros it overrides, or a later unguarded default clobbers it back. This is why
there are two separate `config-*.patch` files rather than one: each diff's context lines pin the
block to the right spot for that era.

- **0.16.0 era** — `__config` has an inner block ending with an **unguarded**
  `#    define _LIBCPP_HAS_C11_ALIGNED_ALLOC 1` (followed by `#  endif`). The diff places the
  override **after that inner block**. (Placing it after the *outer*-guard close instead lets the
  inner `#define …1` run afterward and silently re-breaks the build with
  `undefined symbol: aligned_alloc`. Caught in review; the diff context encodes the correct spot.)
  On this era Patch A is the *entire* fix.

- **0.17-dev era** — there is **no** inner C11 block (the macro was removed from the backend
  decision). The diff places the override after the outer-guard close. The `C11` define is inert
  here, so Patch A alone leaves the backend on `aligned_alloc` — Patch B finishes it.

**Patch B — both `aligned_alloc.h` copies (0.17-dev era only).** Adds an old-glibc exclusion to
each backend `#elif` so old glibc falls through to the `#else` (`posix_memalign`) branch:

```c
// user-side include/__memory/aligned_alloc.h
#  elif (_LIBCPP_STD_VER >= 17 && _LIBCPP_HAS_C11_ALIGNED_ALLOC) \
        && !(defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16)))

// libc++abi-side src/include/aligned_alloc.h
#  elif (!defined(__ANDROID__) || __ANDROID_API__ >= 28) \
        && !(defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 16)))
```

## Script behavior

`patch_zig_libcxx_oldglibc.sh`:

1. **Locate zig**: take the zig install dir as `$1` (or `--zig-prefix <dir>`); resolve
   `LIBCXX=<prefix>/lib/libcxx`. (`prepare-zig.sh` passes `$ZIG_INSTALL_DIR` directly.) The diffs
   are found relative to the script's own directory (`scripts/zig-patches/`).
2. **Era detection**: test for `lib/libcxx/src/include/aligned_alloc.h`.
   - ABSENT → 0.16.0 era: apply `config-0.16.0.patch`.
   - PRESENT → 0.17-dev era: apply `config-0.17-dev.patch` + `aligned_alloc-0.17-dev.patch`.
3. **Apply**: for each selected diff,
   `patch -N -p1 --fuzz=3 -d "$LIBCXX" < scripts/zig-patches/<file>`.
   - `rc == 0` → applied.
   - `rc != 0` with "previously applied"/"Reversed" in patch's output → idempotent no-op; continue.
   - any other `rc != 0` → `die` with which diff failed (a `.rej` is left for diagnosis); the
     wrapper does not blind-edit an unrecognized tree.
   `--fuzz=3` lets a hunk apply despite small surrounding drift. Fuzz favors applying, so a
   mis-applied hunk is possible in principle — the self-verify step below is the backstop that
   rejects it.
4. **Self-verify** (the safety net for fuzzed applies): compile a throwaway aligned-new TU for
   `x86_64-linux-gnu.2.11` with a **bare** command line (no `-D`, no compat object) and assert:
   (a) link succeeds; (b) `objdump -T` shows `posix_memalign` and **not** `aligned_alloc`; (c) max
   `GLIBC_*` symbol version ≤ 2.11. Also compile for `2.17` and assert it still uses `aligned_alloc`
   (no regression). On any failure, restore the originals (from `patch`'s `.orig` backups) and exit
   non-zero.

## Integration

The patch lives in the **msys2-cross** repo (that is where zig is installed and used), not in
anyfs-reader. Hook it into `scripts/prepare-zig.sh`, the script that downloads/extracts zig and
creates the `build/zig` symlink. Call `patch_zig_libcxx_oldglibc.sh "$ZIG_INSTALL_DIR"`
immediately after the symlink is created (after the `ln -sfn … build/zig` line, before the final
"ready" banner). This patches every freshly installed zig right at install time, for both the
default `0.16.0` and any `-dev.*` version the script is invoked with.

`prepare-zig.sh` skips re-extraction when `build/zig-…<ver>/` already exists, but the patch call
runs every invocation; `patch -N` makes that a no-op on an already-patched tree (it reports the
hunks as previously applied and skips them), and re-running after a fresh zig reinstall re-applies
cleanly.

## Verification (containerized, fresh downloads)

Verification runs in a **Docker container** that downloads **pristine** zig tarballs (not the
hand-probed `/opt` installs), to prove the patch script works against official upstream trees:

- A small test harness (e.g. `scripts/test-zig-oldglibc-patch.sh` driving a minimal container)
  that, for each of zig **0.16.0** (tagged) and **0.17.0-dev.657+2faf8debf** (pinned dev build):
  1. downloads the official tarball fresh and extracts it,
  2. runs `patch_zig_libcxx_oldglibc.sh` against it (which self-verifies),
  3. independently re-checks: bare-command-line aligned-new for `x86_64-linux-gnu.2.11` links,
     uses `posix_memalign`, max `GLIBC_*` ≤ 2.11; and `2.17` still uses `aligned_alloc`,
  4. **aarch64 no-op check**: aligned-new for `aarch64-linux-gnu.2.17` builds and still uses
     `aligned_alloc` — the patch's `__GLIBC_MINOR__ < 16` guard is always false on aarch64 (aarch64
     glibc starts at 2.17; there is no pre-2.17 aarch64 port), so the patch must be a harmless no-op,
  5. re-runs the patch script to assert idempotency (second run is a no-op, exit 0).
- The pinned dev build (`0.17.0-dev.657+2faf8debf`) was the live `ziglang.org` master at design time
  and matches the tree this design was verified against. Dev builds rotate off
  `ziglang.org/builds/`; if the pinned tarball 404s, the test falls back to the current master from
  `ziglang.org/download/index.json` and records the new pin.

## Verified evidence

- **0.16.0**, target 2.11, bare command line (override after the inner C11 block): links; backend
  `posix_memalign` (GLIBC_2.2.5); whole-binary max GLIBC 2.10. Target 2.17: unchanged
  (`aligned_alloc`@2.16). Native run prints correct 64-byte alignment. Plain C++ (`std::string`)
  on old glibc unaffected.
- **Self-review catch**: placing Patch A after the *outer*-guard close (instead of after the
  inner C11 block) re-breaks 0.16.0 with `undefined symbol: aligned_alloc`, because the inner
  unguarded `#define …1` runs afterward. Encoding the correct spot in each era's diff context (above)
  is the fix. Verified both the wrong and the corrected placement.
- **GNU patch viability** (this redesign): a `config-0.16.0.patch` applies cleanly to a pristine
  `__config`; survives a +200-line offset via context matching; `patch -N` reports a second apply as
  "previously applied" (idempotent); `--fuzz=3` can apply against a perturbed anchor, confirming
  self-verify must remain the backstop. `.rej` files are produced on hard failure for diagnosis.
- **0.17-dev .657**, 3-file patch, target 2.11: links; backend `posix_memalign` (GLIBC_2.2.5);
  max GLIBC 2.10. Target 2.17: unchanged.
- **0.17-dev .633**: same structure as .657 (confirmed identical backend layout).
- Cache correctness: editing `.cpp` or `.h` spawns a fresh `o/<hash>/` and recompiles; not stale.
- All three zig installs restored pristine after probing (zero patch residue).

## Out of scope (YAGNI)

- Patching more than one zig install per invocation.
- *Fixing* non-x86_64 architectures. Only x86_64 old-glibc is fixed; aarch64 is covered solely by a
  no-op regression check (its glibc floor is 2.17, so the guard never fires). Other arches: revisit
  if a real pre-2.16 target appears (none exists for aarch64).
- A `--dry-run` mode.
- Upstreaming to zig (`libcxx.zig`) — that is a separate "rebuild zig" path, explicitly excluded
  by the constraints here.
