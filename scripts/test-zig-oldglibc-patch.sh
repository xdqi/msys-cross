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
