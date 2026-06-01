#!/bin/bash
# Prepare the MSYS2 target sysroots used at build time (headers/libs/binutils
# for mingw64/mingw32/ucrt64/cygwin). This is the cross-compiler's *target*
# system — NOT the user-facing bootstrap.tar.xz (that is built by
# build_installer.sh from the finished packages).
# Uses native pacman to install the mingw64/mingw32/ucrt64/msys sysroots.
#
# Output: $BOOTSTRAP_PREFIX (default build/bootstrap-prefix)/{mingw64,mingw32,ucrt64,usr}
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
OUT="${BOOTSTRAP_PREFIX:-$PROJECT_ROOT/build/bootstrap-prefix}"
MIRROR="${MSYS2_MIRROR:-https://repo.msys2.org}"

echo "=== msys2-cross bootstrap prefix setup ==="
echo "Output: $OUT"
echo

rm -rf "$OUT"
mkdir -p "$OUT/var/lib/pacman" "$OUT/etc/pacman.d"

cat > "$OUT/etc/pacman.d/pacman.conf" <<ENDCONF
[mingw64]
Server = ${MIRROR}/mingw/mingw64/
SigLevel = Never

[mingw32]
Server = ${MIRROR}/mingw/mingw32/
SigLevel = Never

[ucrt64]
Server = ${MIRROR}/mingw/ucrt64/
SigLevel = Never

[msys]
Server = ${MIRROR}/msys/x86_64/
SigLevel = Never
ENDCONF

_pacman() {
    echo "  -> pacman $*"
    pacman \
        --root="$OUT" \
        --config="$OUT/etc/pacman.d/pacman.conf" \
        --dbpath="$OUT/var/lib/pacman" \
        --noconfirm "$@"
}

echo "=== Installing mingw64 sysroot ==="
# Also install the upstream gcc + gcc-fortran packages: msys-cross-gcc builds only
# the host compiler (make all-gcc) and sources the TARGET runtime libs (libgcc,
# libstdc++, libgfortran, crt, C++ headers) by copying them out of this sysroot
# via `pacman -Ql` (see scripts/extract-target-libs.sh::copy_sysroot_pkg). Letting
# pacman install them resolves the right version/triple/layout automatically.
_pacman -Sy \
    mingw-w64-x86_64-headers mingw-w64-x86_64-crt \
    mingw-w64-x86_64-winpthreads mingw-w64-x86_64-gcc-libs \
    mingw-w64-x86_64-zlib mingw-w64-x86_64-windows-default-manifest \
    mingw-w64-x86_64-gcc mingw-w64-x86_64-gcc-fortran

echo "=== Installing mingw32 sysroot ==="
# NOTE: MSYS2 no longer ships mingw-w64-i686-gcc-fortran (32-bit mingw is being
# retired upstream; the mingw32 repo has the i686 gcc but no gcc-fortran). pacman
# aborts the WHOLE transaction on a single "target not found", and this script runs
# under `set -e`, so we must NOT request the missing package — we install only
# mingw-w64-i686-gcc here. Correspondingly, msys-cross-gcc emits NO
# msys-cross-mingw32-gcc-fortran package: there is no libgfortran to ship, so
# mingw32 is C/C++ only.
_pacman -Sy \
    mingw-w64-i686-headers mingw-w64-i686-crt \
    mingw-w64-i686-winpthreads mingw-w64-i686-gcc-libs \
    mingw-w64-i686-zlib mingw-w64-i686-windows-default-manifest \
    mingw-w64-i686-gcc

echo "=== Installing ucrt64 sysroot ==="
_pacman -Sy \
    mingw-w64-ucrt-x86_64-headers mingw-w64-ucrt-x86_64-crt \
    mingw-w64-ucrt-x86_64-winpthreads mingw-w64-ucrt-x86_64-gcc-libs \
    mingw-w64-ucrt-x86_64-zlib mingw-w64-ucrt-x86_64-windows-default-manifest \
    mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gcc-fortran

echo "=== Installing cygwin/msys sysroot ==="
# Also install the msys-repo gcc package (pulls gcc-libs etc.): like msys-cross-gcc,
# msys-cross-cygwin-gcc builds only the host compiler (make all-gcc) and sources the
# TARGET runtime libs (libgcc/crt, libstdc++, libsupc++, C++ headers) by copying them
# out of this sysroot via copy_sysroot_pkg. The triple (x86_64-pc-cygwin) and version
# (15.2.0) match ours exactly, so pacman resolves them with no remap. Do NOT add
# gcc-fortran (the cygwin port ships no Fortran).
_pacman -Sy \
    msys2-runtime-devel msys2-w32api-headers msys2-w32api-runtime \
    gcc

echo "=== Fetching specs-helper gcc drivers (for darwin/foreign-host GCC builds) ==="
# A Canadian-cross GCC build (build=linux, host=foreign e.g. arm64 macOS, target=mingw/
# cygwin) can't run its own host xgcc for make's `specs` pass (GCC_FOR_TARGET -dumpspecs)
# on the Linux build machine. The dumped specs depend ONLY on the target, so the GCC
# PKGBUILDs override GCC_FOR_TARGET to a build-runnable same-target gcc: the project's own
# x86_64-linux-hosted msys-cross-<target>-gcc.
#
# We need the gcc DRIVER + its backends (libexec cc1/cc1plus/lto1/collect2): `-dumpspecs`
# only needs the driver, but GCC's `all-gcc` ALSO runs the host self-tests
# (`$(GCC_FOR_SELFTESTS) -fself-test`), whose recipe invokes the driver which spawns cc1.
# A driver-only helper makes that fail ("cannot execute 'cc1'"); with the backends present
# the driver finds its relative ../libexec/.../cc1 and the self-test no-ops out ("self-tests
# are not enabled in this build"). So extract bin/<triple>-gcc + libexec/gcc/** (~136 MB
# each — still ~half the full ~1.2 GB package, and no deps, no root). Land them in
# $OUT/specs-helper, a fixed path deliberately NOT on PATH so these build-time helpers can
# never shadow the cross toolchain.
SPECS_REPO="${MSYS_CROSS_REPO:-https://msys.kosaka.moe/repo}"
SPECS_ROOT="$OUT/specs-helper"
mkdir -p "$SPECS_ROOT/bin"
# target subdir -> gcc triple (the driver name inside each package is <triple>-gcc).
declare -A _SPECS_TRIPLE=(
    [mingw32]=i686-w64-mingw32 [mingw64]=x86_64-w64-mingw32
    [ucrt64]=x86_64-w64-mingw32ucrt [cygwin]=x86_64-pc-cygwin
)
# Resolve current package FILENAMEs from the repo db so versions track the repo (and
# cygwin's distinct version is handled automatically — no hardcoding).
_specs_tmp="$SPECS_ROOT/.dbtmp"
rm -rf "$_specs_tmp"; mkdir -p "$_specs_tmp"
if curl -fsSL --connect-timeout 20 --retry 3 "$SPECS_REPO/msys-cross.db" -o "$_specs_tmp/db.tar.gz" \
   && tar xf "$_specs_tmp/db.tar.gz" -C "$_specs_tmp" 2>/dev/null; then
    for _sub in mingw32 mingw64 ucrt64 cygwin; do
        _tr="${_SPECS_TRIPLE[$_sub]}"
        _fn=$(grep -hoE "msys-cross-${_sub}-gcc-[0-9][^/]*-x86_64\.pkg\.tar\.zst" "$_specs_tmp"/*/desc 2>/dev/null | sort -u | head -1)
        if [ -z "$_fn" ]; then echo "  WARNING: no $_sub gcc in repo db (skip)"; continue; fi
        if curl -fsSL --connect-timeout 30 --retry 3 "$SPECS_REPO/$_fn" -o "$_specs_tmp/pkg.zst" \
           && bsdtar xf "$_specs_tmp/pkg.zst" -C "$SPECS_ROOT" \
                "bin/${_tr}-gcc" "libexec/gcc" 2>/dev/null \
           && [ -x "$SPECS_ROOT/bin/${_tr}-gcc" ]; then
            echo "  + ${_tr}-gcc + libexec backends  (from $_fn)"
        else
            echo "  WARNING: failed to extract ${_tr}-gcc from $_fn"
        fi
        rm -f "$_specs_tmp/pkg.zst"
    done
    echo "  specs-helper drivers under $SPECS_ROOT/bin (NOT on PATH, drivers only)"
else
    echo "  WARNING: could not fetch $SPECS_REPO/msys-cross.db — darwin GCC builds will lack a GCC_FOR_TARGET proxy"
fi
rm -rf "$_specs_tmp"

echo
echo "=== Bootstrap prefix ready ==="
echo "  BOOTSTRAP_PREFIX=$OUT"
echo "  $(ls -d "$OUT"/mingw64 "$OUT"/mingw32 "$OUT"/ucrt64 "$OUT"/usr 2>/dev/null | xargs -I{} basename {})"
