# Probe: darwin (arm64 macOS host) cross-build of pacman's deps under zig cc

Standalone probe (NOT the makepkg flow) cross-compiling pacman's core deps to
aarch64-macos.11.0 with the repo's zigcc wrapper, to find the real blockers before
wiring darwin pacman into build-darwin.sh. Probe dir: /tmp/darwin-pacman-probe.

## Results

| dep | result | notes |
|-----|--------|-------|
| **openssl 3.6.2** | ✅ full success | `./Configure ... darwin64-arm64-cc` (its own target name, not autoconf --host); `make build_libs` → libcrypto.a + libssl.a arm64 Mach-O, 0 errors. |
| **libarchive 3.8.7** | ✅ full success | autoconf `--host=aarch64-apple-darwin20 --build=x86_64-linux-gnu`; zstd+zlib backends OK (our .pkg.tar.zst needs only those). Needed cross cache overrides (see below). |
| **curl 8.20.0** | ⚠️ blocked on ONE framework | configure succeeds (openssl/zlib/zstd detected, http2/brotli cut); `make` fails compiling macos.c (needs SystemConfiguration framework). |

## Two cross-build mechanics that apply to ALL darwin deps

1. **Archive format**: a dep that packs its `.a` with the system GNU `ar` (e.g. openssl's
   `AR=ar`) produces a GNU-format archive of arm64 Mach-O .o, which zig's Mach-O linker
   rejects with `error: unknown cpu architecture: <number>` (it misreads the GNU symbol
   table). FIX: pack with **`zig ar --format=darwin`** (plain `zig ar` defaults to gnu and
   ALSO fails). In the real makepkg flow, setup_zig_env sets AR="zig ar" — for darwin it
   must be `zig ar --format=darwin` (or the dep's AR overridden so). build_deps' libz/libzstd
   were fine only because... actually they too must be repacked --format=darwin for a darwin
   consumer (verified: repacking openssl+zlib+zstd+libarchive as --format=darwin let curl's
   openssl probe link).

2. **autoconf cross-detect misfires on the zig macOS SDK → use `ac_cv_*` cache overrides**
   (the standard cross-compile mechanism, NOT source edits):
   - libarchive: a whole batch of wchar funcs (wcscpy/wcslen/wcscmp/wcrtomb/wctomb/wmemcmp/
     wmemcpy/wmemmove) probed `no` (the autoconf link-test conftest fails under zig+darwin
     even though macOS has them) → `ac_cv_func_wcscpy=yes ...`. Confirmed macOS has them.
   - curl: `pthread_create` probed `no` (macOS pthread is in libSystem, not -lpthread) →
     `ac_cv_func_pthread_create=yes`.

## The real ceiling: zig's macOS SDK has NO frameworks / some system headers

zig ships only base libc headers (TargetConditionals.h etc.), NOT macOS frameworks or
membership.h. Deps that touch deep macOS system APIs hit this:
- libarchive: `archive_disk_acl_darwin.c` needs `<membership.h>` (mbr_uid_to_uuid, …).
  WORKAROUND (no source edit, pacman doesn't need disk ACLs): tell configure the symbols are
  absent so it doesn't pick the darwin ACL backend —
  `ac_cv_header_membership_h=no ac_cv_func_mbr_uid_to_uuid=no ac_cv_func_mbr_uuid_to_id=no`
  `ac_cv_have_decl_ACL_TYPE_EXTENDED=no ac_cv_have_decl_ACL_TYPE_NFS4=no`
  → ARCHIVE_ACL_* all undef → libarchive.a builds clean (4.3 MB arm64 Mach-O).
- curl: `macos.c` needs `<SystemConfiguration/SCDynamicStoreCopySpecific.h>`. This is curl's
  `Curl_macos_init` calling `SCDynamicStoreCopyProxies` to read the macOS system PROXY
  settings — NOT socket/ipv6 itself. curl_setup.h:402 gates it behind
  `#if defined(__APPLE__) && !defined(USE_ARES)` + `TARGET_OS_MAC && !iPhone && defined(USE_IPV6)`,
  so it's coupled to USE_IPV6 only by code organization (it sits next to the IPv6/NAT64
  address-synthesis block), not by any real ipv6→framework dependency.
  Pure-configure ways to avoid it WITHOUT editing curl_setup.h:
    * `--disable-ipv6` → USE_IPV6 undef → macos.c empty (verified). Cost: no ipv6 (mirror
      pulls work over ipv4/dual-stack, so acceptable but not ideal).
    * `--enable-ares` → USE_ARES defined → whole `#if` false, KEEPS ipv6, but adds a c-ares dep.
  `--disable-proxy` does NOT help (the macro doesn't key off proxy).

## Recommendation
The framework gap recurs (libarchive membership.h, curl SystemConfiguration; pacman/others
may follow). Cleanest is to feed zigcc a real macOS SDK via `-isysroot` (Xcode CLT SDK or an
osxcross SDK tarball) so frameworks + system headers exist — solves all of these at once and
keeps full features (ipv6, ACL). The `ac_cv_*=no` / `--disable-ipv6` route works per-dep but
is whack-a-mole. Decision pending.

Verified arch of every produced static lib: arm64 Mach-O. openssl + libarchive are
end-to-end cross-built; curl is one framework away.
