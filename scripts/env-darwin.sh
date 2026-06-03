# Portable per-target build env for HOST = arm64 macOS 11.0 (cross from a Linux build
# machine). Single source of truth for the per-target cross vars. Sourced by:
# scripts/build-darwin.sh, scripts/makepkg-darwin-arm64.conf.
#
# Contains ONLY exports valid in a plain shell AND a makepkg subprocess (NOT CARCH/
# CHOST/OPTIONS/PKGEXT — those are makepkg-only, set in the .conf). The values ride
# through `runuser` (exported vars survive; only PATH is reset) and the makepkg
# `--config` -> build() boundary.
export ZIG_TARGET="aarch64-macos.11.0"
export _MSYS_CROSS_HOST="aarch64-apple-darwin20"
# _MSYS_CROSS_BUILD stays unset -> build machine is Linux (host != build => cross mode).
export _MSYS_CROSS_DUMPSPECS=1
export MSYS_CROSS_ENV_LOADED=1   # guard marker (no leading _ — see naming spec)
