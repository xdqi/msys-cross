# pacman-static from source (zig-cc-gnu.2.11) — design

Date: 2026-06-01

## Context

The `msys-cross-pacman` package wraps Morganamilo's static pacman so the
msys2-cross toolchain installs into a user-owned, relocatable prefix without
root. It currently **downloads the prebuilt archlinuxcn `pacman-static.pkg.tar.xz`
and binary-patches it** (`patch-pacman-nonroot.sh`) for three behaviours:

1. drop the hard root requirement,
2. clear `ARCHIVE_EXTRACT_OWNER` so extraction never chowns,
3. redirect the system alpm hook dir so no MSYS2/Windows package hook Execs on
   the Linux host.

Binary patching is fragile (re-located on every archlinuxcn rebuild; relies on an
unstripped binary; byte/immediate assertions). We now have `deps/pacman-static`
vendored as a submodule (the AUR `pacman-static.git`, committed at `69175db`),
which builds pacman + its static deps from source. This design **replaces the
binary patches with source patches and builds pacman ourselves** with the repo's
existing `zig cc` toolchain — the same inherit-and-transform pattern used by
`pkgs/msys-cross-cygwin-gcc`.

Outcome: a self-built, source-patched `pacman-static` binary, no archlinuxcn
download, the three fixes expressed at the source where intent is explicit.

## Decisions (settled with the user)

- **Scope:** full from-source — build everything the AUR PKGBUILD builds
  (curl, openssl, libarchive, gpgme, libassuan, libgpg-error, zlib, xz, bzip2,
  zstd, brotli, nghttp2, libseccomp → pacman).
- **Toolchain:** reuse the existing zig target `x86_64-linux-gnu.2.11` (the
  `scripts/zigcc` wrapper), **not** a musl target. glibc 2.11 is old enough to be
  portable, and the wrapper is already sccache-wired.
- **Linking model:** mostly-static — static-link all the from-source deps, link
  glibc **dynamically** (no global `-static`). Avoids glibc NSS / static-link
  fragility; the binary runs on any glibc ≥ 2.11 host.
- **Approach:** inherit the AUR PKGBUILD and **sed-transform** its monolithic
  `build()` (cygwin-gcc style), rather than forking the build logic.
- **Package layout:** rework `pkgs/msys-cross-pacman` in place. From the whole
  AUR build we keep **only the `pacman-static` binary**. The existing
  `msys-pacman` wrapper and `pacman.conf` stay. `patch-pacman-nonroot.sh` is
  deleted.
- **Hook dir name:** redirect `SYSHOOKDIR` to `/usr/share/libalpm/msys-cross-hooks/`
  (a meaningful name, not `.nope`).
- **Workspace:** done in an isolated worktree; the submodule was committed first.

## Architecture

Mirror `pkgs/msys-cross-cygwin-gcc/PKGBUILD`'s inherit-and-transform model.

### inherit_aur helper (`scripts/msys-cross-common.sh`)

Add `inherit_aur <deps-subdir>` analogous to `inherit_msys2`: source
`deps/<subdir>/PKGBUILD`, rename its `prepare`/`build`/`package` to
`_aur_prepare`/`_aur_build`/`_aur_package`, and capture its `source`/`sha512sums`/
version vars so the package can reuse and selectively override them.

### pkgs/msys-cross-pacman/PKGBUILD

1. `inherit_aur "pacman-static"`.
2. **Override the toolchain via re-export, not by sed-ing `build()`.** The AUR
   PKGBUILD sets `CC=musl-gcc` and `LDFLAGS="$LDFLAGS -static"` at **top level**
   (lines 121-139, run once when the PKGBUILD is sourced); `build()` only
   *references* `${CC}`/`${CFLAGS}`/`${LDFLAGS}`. So after `inherit_aur` sources
   it, our PKGBUILD body re-exports:
   - `CC="$_wrappers/zigcc"`, `CXX`/`AR`/`RANLIB` (setup_zig_env style) — wins
     because it runs after the inherited top-level exports and `build()` reads
     `${CC}` at call time (e.g. its bzip2 `s|CC=gcc|CC=${CC}|` sed).
   - `LDFLAGS` re-set to mostly-static (from-source libs in `-Wl,-Bstatic ...
     -Wl,-Bdynamic`, **no** global `-static`).
   - On `x86_64` the i686 `-fno-stack-protector` and GCC≥16 `-fno-link-libatomic`
     branches are not taken, so only `CC` and `-static` need overriding.
   A small sed of `build()` is reserved for genuine in-function Arch-isms that a
   re-export can't reach: the **openssl `./Configure` `CARCH` target table** (pin
   `linux-x86_64`). Everything else (the per-dep
   `./configure`/`./Configure`/`cmake`/`meson` sequence) is kept intact.
3. **prepare()** wraps `_aur_prepare` and then applies our 3 source patches to the
   `pacman/` tree.
4. **package()** overrides `_aur_package`: install only `libexec/pacman-static`,
   the `msys-pacman` wrapper (`bin/`), and `pacman.conf` (`etc/pacman.d/`).
5. **check()** reworked to validate the source-patched binary behaviourally
   (non-root gate passes; no chown; redirected hook dir present) — no byte asserts.

### Source patches (replace the binary patches)

Applied to the `pacman/` source in `prepare()`:

- `0001-nonroot-allow-install.patch` — neutralize the
  `if(myuid > 0 && needs_root())` gate in `src/pacman/pacman.c main()` so a
  non-root `-S`/`-U` into a user-owned `--root` is allowed.
- `0002-no-extract-owner.patch` — remove `ARCHIVE_EXTRACT_OWNER` from the flag set
  in `lib/libalpm/add.c` `perform_extraction()` (leaving PERM/TIME/UNLINK/XATTR/
  SECURE_SYMLINKS — all non-root-safe).
- `0003-syshookdir-msys-cross.patch` — change the `SYSHOOKDIR` definition
  (`meson.build` → `config.h`) from `.../libalpm/hooks/` to
  `.../libalpm/msys-cross-hooks/`, so the root-rebased system hook dir
  (`$PREFIX/usr/share/libalpm/msys-cross-hooks/`) is one packages never populate
  and no MSYS2/Windows hook Execs on the Linux host. Admin hooks still work via the
  wrapper's `--hookdir`.

### Unchanged from the prior commit (88ba214)

- `msys-pacman` wrapper — already pins `--cachedir`/`--gpgdir`/`--hookdir` and
  mkdir's the prefix dirs.
- `pacman.conf` — `NoExtract = *.exe`.

### Deleted

- `pkgs/msys-cross-pacman/patch-pacman-nonroot.sh`.

## Data / control flow

```
deps/pacman-static/PKGBUILD  (AUR, submodule)
   │  inherit_aur
   ▼
pkgs/msys-cross-pacman/PKGBUILD
   prepare(): _aur_prepare + 0001/0002/0003 source patches
   build():   _aur_build with CC/LDFLAGS re-exported (zigcc gnu.2.11,
              mostly-static) + openssl CARCH pinned → 13 static deps → pacman-static
   package(): pacman-static + wrapper + pacman.conf
   check():   behavioural assertions on the source-patched binary
```

## Risks to validate during implementation

1. **zig-cc-gnu.2.11 building the crypto/transport stack** — openssl
   (`./Configure linux-x86_64`), gpgme, libseccomp (needs kernel headers; zig
   provides them), curl, libarchive. These are the most likely to need per-dep
   flag tweaks under clang/zig vs gcc/musl.
2. **Mostly-static link resolution** — every from-source symbol resolves with the
   `-Wl,-Bstatic`/`-Bdynamic` bracketing and no musl assumptions.
3. **Override completeness** — re-exporting `CC`/`LDFLAGS` covers the top-level
   Arch-isms; the only in-`build()` Arch-ism is the openssl `CARCH` target table
   (pinned via a small sed). Confirm no other place hard-codes `musl-gcc`/`-static`
   inside `build()` (grep audit during implementation).
4. **sccache across ~13 sequential dep builds** — the existing wrapper handles it;
   confirm no regressions.

## Verification

1. **Build:** `pkgs/msys-cross-pacman` builds end-to-end under the repo's build
   driver with zig-cc-gnu.2.11; produces a `pacman-static` that is a dynamic-glibc,
   otherwise-static ELF (`ldd` shows only libc/ld-linux; `file` confirms
   interpreter present, deps statically linked).
2. **Source-patch behaviour (non-root):** install a root-authored test package via
   the wrapper as a normal user → files owned by the user (no chown); the `.exe`
   skipped (NoExtract); a packaged `usr/share/libalpm/hooks/*.hook` does **not**
   run; cache lands in the prefix. (Same matrix proven for the binary-patch
   version in 88ba214.)
3. **check():** the reworked `check()` passes under makepkg (non-root) and fails on
   an unpatched build (regression guard).
4. **End-to-end:** `scripts/test-docker.sh <distro> <toolchain>` installs
   `msys-cross-filesystem` + the gcc package and compiles the test programs using
   the from-source pacman.
