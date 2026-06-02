# Design: darwin (arm64 macOS host) pacman — dependency scope

## Why

The arm64-macOS-host toolchain needs its own `msys-cross-pacman` + bootstrap (arm64, repo
= /repo-darwin) so a Mac user installs by downloading the darwin bootstrap, not by hand-editing
a pacman.conf. The from-source `msys-cross-pacman` (built with zig cc, on branch
worktree-pacman-from-source) inherits the AUR `pacman-static` PKGBUILD, which builds pacman +
**13 static deps**. Most are unnecessary on macOS. This scopes which deps the darwin build keeps.

## Reference: Homebrew's `makepkg` formula (what macOS actually needs)

Homebrew's `makepkg` formula (== the pacman/makepkg the user already has on the M1) declares only:
- runtime: **libarchive**, **openssl@3**, bash, fakeroot; `uses_from_macos "libxslt"` (macOS ships it)
- build: meson, ninja, pkgconf; `-Di18n=false` on macOS
- NOT gpgme, NOT curl, NOT libseccomp.

## The 13 AUR pacman-static deps, classified for darwin

KEEP (cross-build for aarch64-macos):
- **libarchive** — read/write .pkg.tar.zst (Homebrew keeps it too). REQUIRED.
- **openssl** — crypto + TLS for curl. REQUIRED.
- **curl** — `pacman -S` online fetch from /repo-darwin. KEEP, but **without http2/brotli** (basic
  https GET over openssl TLS suffices; nghttp2/brotli are optimizations). Drop the
  `--with-nghttp2`/`--with-brotli-*` configure args.
- (zlib, zstd — already provided by scripts/build_deps.sh for the arm64 target; reused, not rebuilt.)

DROP:
- **nghttp2** — curl http2 only (user's call: cut).
- **brotli** — curl brotli only (user's call: cut).
- **gpgme + libgpg-error + libassuan** — signature verification; we run SigLevel=Never. Cut all 3.
- **libseccomp** — Linux-only sandbox; macOS has no equivalent. Cut.

VERIFY-THEN-DECIDE:
- **xz (liblzma) / bzip2** — libarchive's .xz/.bz2 backends. macOS ships liblzma/libbz2; if zig's
  macOS sysroot exposes them, libarchive can use the system ones (no separate cross-build). If not,
  cross-build them too. Determine during implementation.

Net: from 13 deps down to **~3 cross-built (libarchive, openssl, curl)** + zlib/zstd reused
(+ maybe xz/bz2). curl is configured without http2/brotli.

## Implementation outline (not yet done)
1. msys-cross-pacman PKGBUILD: when ZIG_TARGET is a macOS target, drop the gpgme/libgpg-error/
   libassuan/libseccomp/nghttp2/brotli build blocks (the PKGBUILD already awk/sed-edits the AUR
   build to drop zstd/zlib; extend that to skip these), and curl configure without
   --with-nghttp2/--with-brotli. pacman meson without gpgme.
2. Ship a darwin pacman.conf (Server = https://msys.kosaka.moe/repo-darwin, Architecture = arm64)
   in the darwin msys-cross-pacman package — baked into the bootstrap, not hand-edited.
3. build-darwin.sh: also build msys-cross-filesystem + msys-cross-pacman (+ ca-certificates) for
   arm64, then run build_installer.sh with the darwin PKGDEST/pacman.conf to emit a darwin
   bootstrap.tar.xz published in the build-darwin-* release.
4. Foundation pkgs (filesystem/pacman) currently arch=('x86_64'); the darwin run uses
   --ignorearch + the darwin conf (CARCH=arm64) like the toolchain pkgs.

## Open verification points
- pacman/libarchive/curl cross to aarch64-macos under zig cc (configure host probes; libseccomp/gpgme
  removal must be clean).
- xz/bz2 from the macOS SDK vs cross-built.
- fakeroot on macOS for makepkg packaging (Homebrew depends on it) — only matters if the Mac REBUILDS
  packages; for install-only (pacman -U / -S) it's not needed.
