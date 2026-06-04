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
# binutils: the native <triple>-{as,ld,objdump}.exe live in the -binutils package (gcc
# only depends on it, doesn't bundle it). Needed for the wine wrappers used by GCC 16's
# secrel32 configure probe on the darwin host (prepare-build-sysroot generates as/ld/objdump
# wrappers from these; the gcc.exe wrapper comes from the -gcc package).
_pacman -Sy \
    mingw-w64-x86_64-headers mingw-w64-x86_64-crt \
    mingw-w64-x86_64-winpthreads mingw-w64-x86_64-gcc-libs \
    mingw-w64-x86_64-zlib mingw-w64-x86_64-windows-default-manifest \
    mingw-w64-x86_64-binutils \
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
    mingw-w64-i686-binutils \
    mingw-w64-i686-gcc

echo "=== Installing ucrt64 sysroot ==="
_pacman -Sy \
    mingw-w64-ucrt-x86_64-headers mingw-w64-ucrt-x86_64-crt \
    mingw-w64-ucrt-x86_64-winpthreads mingw-w64-ucrt-x86_64-gcc-libs \
    mingw-w64-ucrt-x86_64-zlib mingw-w64-ucrt-x86_64-windows-default-manifest \
    mingw-w64-ucrt-x86_64-binutils \
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
    binutils gcc

echo "=== Generating wine specs-helpers (for darwin/foreign-host GCC builds) ==="
# A Canadian-cross GCC build (build=linux, host=foreign e.g. arm64 macOS, target=mingw/
# cygwin) can't run its own host xgcc for make's `specs`/`self-test` passes
# (`$(GCC_FOR_TARGET) -dumpspecs`/`-fself-test`) on the Linux build machine — the host
# xgcc is an arm64 Mach-O. The dumped specs depend ONLY on the target, so the GCC
# PKGBUILDs override GCC_FOR_TARGET to a build-runnable, SAME-target gcc.
#
# The MSYS2 sysroots installed above ALREADY include the native Windows gcc.exe for each
# target (bin/<triple>-gcc.exe + cc1.exe + DLLs) — they're SAME-target gccs, so running
# them under wine produces identical specs and lets -fself-test no-op. We write a tiny
# wine wrapper per target into $OUT/specs-helper/bin/<our-triple>-gcc (a fixed path the
# GCC PKGBUILDs reference, deliberately NOT on PATH). This needs no remote download and
# no dependency on the linux package build, so the darwin build can run fully in parallel.
# Requires `wine` (the darwin entrypoint installs it; on a linux-only run the wrappers are
# simply never invoked).
SPECS_ROOT="$OUT/specs-helper"
SPECS_WINEPREFIX="$SPECS_ROOT/.wine"
mkdir -p "$SPECS_ROOT/bin"
# our darwin target triple  ->  "sysroot-subdir:exe-basename" of the native gcc.exe.
# NB: MSYS2's ucrt64 gcc is internally triple x86_64-w64-mingw32 (the exe is named so),
# even though our ucrt darwin target triple is x86_64-w64-mingw32ucrt — the dumped specs
# are target-identical, so the ucrt wrapper invokes the ucrt64 sysroot's exe.
declare -A _SPECS_SRC=(
    [i686-w64-mingw32]="mingw32:i686-w64-mingw32-gcc.exe"
    [x86_64-w64-mingw32]="mingw64:x86_64-w64-mingw32-gcc.exe"
    [x86_64-w64-mingw32ucrt]="ucrt64:x86_64-w64-mingw32-gcc.exe"
    [x86_64-pc-cygwin]="usr:x86_64-pc-cygwin-gcc.exe"
)
if command -v wine >/dev/null 2>&1; then
    # One shared wineprefix, initialized once (no Windows-version tweak needed — verified
    # that cygwin/mingw gcc.exe -dumpspecs emit identical specs on a default prefix).
    WINEPREFIX="$SPECS_WINEPREFIX" WINEDEBUG=-all wineboot -i >/dev/null 2>&1 || true
    for _tr in "${!_SPECS_SRC[@]}"; do
        _sub="${_SPECS_SRC[$_tr]%%:*}"; _exe="${_SPECS_SRC[$_tr]#*:}"
        _exedir="$OUT/$_sub/bin"
        if [ ! -x "$_exedir/$_exe" ]; then
            echo "  WARNING: native gcc.exe not found for $_tr ($_exedir/$_exe) — skip"
            continue
        fi
        cat > "$SPECS_ROOT/bin/${_tr}-gcc" <<WRAP
#!/bin/sh
# wine specs-helper for GCC_FOR_TARGET. The native Windows $_exe is the same target as
# the darwin host gcc, so its -dumpspecs output matches. Used by GCC's all-gcc for two
# things that otherwise run the unrunnable arm64 host xgcc:
#   - the \`specs\` pass (-dumpspecs): runs fine under wine.
#   - the host self-tests (-fself-test): these are MEANINGLESS for a foreign-host cross
#     build, and the recipe feeds Unix /dev/null which a Windows gcc.exe rejects ("input
#     file is the same as output file"). So short-circuit any -fself-test invocation to a
#     no-op (exit 0) — equivalent to the upstream "self-tests are not enabled" result.
export WINEPREFIX="$SPECS_WINEPREFIX" WINEDEBUG=-all
export WINEPATH="$_exedir"   # so gcc.exe finds its sibling DLLs + cc1.exe
for a in "\$@"; do
    case "\$a" in -fself-test|-fself-test=*) exit 0 ;; esac
done
exec wine "$_exedir/$_exe" "\$@"
WRAP
        chmod +x "$SPECS_ROOT/bin/${_tr}-gcc"
        echo "  + ${_tr}-gcc -> wine $_sub/bin/$_exe"
    done

    # ---- wine wrappers for as / ld / objdump (GCC 16 secrel32 configure probe) ----
    # GCC 16's configure has a Windows-TLS guard (PR80881) that, for an EXTERNAL (non-
    # in-tree) linker, ACTUALLY RUNS as/ld/objdump on a `.secrel32 foo` conftest. On the
    # darwin host those tools are arm64 Mach-O and can't execute on the x86_64 Linux
    # builder, so the probe dies with "Error occurred while checking for broken secrel32
    # relocations" before make even starts. The conftest is target-only (the relocation
    # is a property of the mingw target, not the host), so the MSYS2 sysroot's native
    # <triple>-{as,ld,objdump}.exe — run under wine — produce identical, correct results.
    # We point GCC configure's gcc_cv_as/gcc_cv_ld/gcc_cv_objdump at these wrappers (darwin
    # gcc PKGBUILD). They take Unix paths and hand them to the PE tool unchanged: wine
    # accepts forward-slash Unix paths for files under the current dir (the conftest runs
    # in a temp cwd), so no path translation is needed for this probe. make all-gcc is
    # host-only (no target libgcc/libstdc++ here — those are copied from the sysroot), so
    # the real compile never invokes these target tools; only configure's probe does.
    declare -A _TOOLS_SUB=(
        [i686-w64-mingw32]=mingw32
        [x86_64-w64-mingw32]=mingw64
        [x86_64-w64-mingw32ucrt]=ucrt64
        [x86_64-pc-cygwin]=usr
    )
    for _tr in "${!_TOOLS_SUB[@]}"; do
        _sub="${_TOOLS_SUB[$_tr]}"
        _exedir="$OUT/$_sub/bin"
        # Per-target native binutils naming differs by repo:
        #   mingw64/mingw32  -> triple-prefixed in <sub>/bin (x86_64-w64-mingw32-as.exe etc.)
        #   ucrt64           -> internally the mingw32 triple (x86_64-w64-mingw32-*), in ucrt64/bin
        #   cygwin (msys repo) -> BARE names in usr/bin (as.exe/ld.exe/objdump.exe); the
        #                         triple-prefixed copies live under usr/x86_64-pc-cygwin/bin.
        # _bprefix is the filename prefix ("" = bare). _exedir is where they live.
        case "$_tr" in
            x86_64-w64-mingw32ucrt) _bprefix="x86_64-w64-mingw32-" ;;
            x86_64-pc-cygwin)       _bprefix="" ;;
            *)                      _bprefix="${_tr}-" ;;
        esac
        for _tool in as ld objdump; do
            _exe="${_bprefix}${_tool}.exe"
            if [ ! -x "$_exedir/$_exe" ]; then
                echo "  WARNING: native $_tool.exe not found for $_tr ($_exedir/$_exe) — skip"
                continue
            fi
            cat > "$SPECS_ROOT/bin/${_tr}-${_tool}" <<WRAP
#!/bin/sh
# wine wrapper for GCC configure's external secrel32 probe. The native Windows
# $_exe is the same TARGET as the darwin host's $_tool, so its output on the
# target-only .secrel32 conftest matches. Used only by configure (gcc_cv_$_tool);
# make all-gcc is host-only and never invokes the target $_tool.
export WINEPREFIX="$SPECS_WINEPREFIX" WINEDEBUG=-all
export WINEPATH="$_exedir"   # so the .exe finds its sibling DLLs
exec wine "$_exedir/$_exe" "\$@"
WRAP
            chmod +x "$SPECS_ROOT/bin/${_tr}-${_tool}"
            echo "  + ${_tr}-${_tool} -> wine $_sub/bin/$_exe"
        done
    done

    echo "  wine specs-helpers under $SPECS_ROOT/bin (NOT on PATH)"
else
    echo "  wine not installed — skipping specs-helper generation (linux-only build, not needed)"
fi

echo
echo "=== Bootstrap prefix ready ==="
echo "  BOOTSTRAP_PREFIX=$OUT"
echo "  $(ls -d "$OUT"/mingw64 "$OUT"/mingw32 "$OUT"/ucrt64 "$OUT"/usr 2>/dev/null | xargs -I{} basename {})"
