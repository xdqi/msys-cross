# Portable per-target build env for HOST = build = x86_64 Linux (glibc), the native case.
# Single source of truth for the per-target cross vars. Sourced by: scripts/build.sh,
# scripts/makepkg-linux-x86_64.conf.
#
# Contains ONLY exports valid in a plain shell AND a makepkg subprocess (NOT CARCH/
# CHOST/OPTIONS/PKGEXT — those are makepkg-only, set in the .conf). The values ride
# through `runuser` (exported vars survive; only PATH is reset) and the makepkg
# `--config` -> build() boundary.
export ZIG_TARGET="x86_64-linux-gnu.2.11"
export MSYS_CROSS_HOST="x86_64-linux-gnu"
export MSYS_CROSS_BUILD="x86_64-linux-gnu"
# MSYS_CROSS_DUMPSPECS intentionally UNSET on linux (native xgcc runs directly).
export MSYS_CROSS_ENV_LOADED=1   # guard marker — consumers assert this was sourced
