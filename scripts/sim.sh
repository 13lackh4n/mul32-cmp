#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# sim.sh - compile and run tb_mult32 with Vivado xsim for one configuration.
#
#   scripts/sim.sh -m <dut module> -f <rtl file> [-f <rtl file> ...]
#                  [-s SIGNED_MODE] [-p PIPE_STAGES] [-x "<extra params>"]
#                  [-v <vector file>] [-t <tag>] [-D <define> ...] [-- <xsim plusargs>]
#
#   -x   extra parameter overrides, e.g. -x ".USE_BOOTH(1)"
#   -v   vector file (default: vectors/vec_{signed,unsigned}_smoke.hex
#        chosen from -s)
#   -t   build/log directory name under build/sim/ (default derived)
#   -D   extra compile-time define for xvlog (repeatable), e.g. -D DUMP_VCD
#        (the xsim equivalent of +define+DUMP_VCD)
#   --   everything after is passed to the testbench as plusargs,
#        e.g. -- +WAIT +LATENCY=33
#
# Exit status is 0 only if the testbench prints "RESULT: PASS".
# Log: build/sim/<tag>/sim.log
# ----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO_BIN="${VIVADO_BIN:-/c/Xilinx/2025.1.1/Vivado/bin}"
export PATH="$VIVADO_BIN:$PATH"

if command -v xvlog.bat >/dev/null 2>&1; then
    XVLOG=xvlog.bat; XELAB=xelab.bat; XSIM=xsim.bat
elif command -v xvlog >/dev/null 2>&1; then
    XVLOG=xvlog; XELAB=xelab; XSIM=xsim
else
    echo "sim.sh: Vivado xsim (xvlog/xelab/xsim) not found; set VIVADO_BIN" >&2
    exit 2
fi

# Native path for the Windows tools (no-op elsewhere).
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

DUT=""; SM=0; PS=2; EXTRA=""; VEC=""; TAG=""; SRCS=(); DEFS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) DUT="$2"; shift 2 ;;
        -f) SRCS+=("$2"); shift 2 ;;
        -s) SM="$2"; shift 2 ;;
        -p) PS="$2"; shift 2 ;;
        -x) EXTRA="$2"; shift 2 ;;
        -v) VEC="$2"; shift 2 ;;
        -t) TAG="$2"; shift 2 ;;
        -D) DEFS+=(-d "$2"); shift 2 ;;
        --) shift; break ;;
        *)  echo "sim.sh: unknown option $1" >&2; exit 2 ;;
    esac
done
PLUSARGS=("$@")

[[ -n "$DUT" && ${#SRCS[@]} -gt 0 ]] || { echo "sim.sh: -m and -f are required" >&2; exit 2; }
if [[ -z "$VEC" ]]; then
    [[ "$SM" == 1 ]] && VEC="$ROOT/vectors/vec_signed_smoke.hex" \
                     || VEC="$ROOT/vectors/vec_unsigned_smoke.hex"
fi
[[ -f "$VEC" ]] || { echo "sim.sh: vector file $VEC not found (run tb/golden.py)" >&2; exit 2; }
VEC="$(cd "$(dirname "$VEC")" && pwd)/$(basename "$VEC")"    # absolute: xsim runs in $BUILD
if [[ -z "$TAG" ]]; then
    TAG="${DUT}_s${SM}_p${PS}$(echo "$EXTRA" | tr -c 'A-Za-z0-9' '_' | sed 's/_\+/_/g; s/_$//')"
fi

BUILD="$ROOT/build/sim/$TAG"
rm -rf "$BUILD"; mkdir -p "$BUILD"

# Configuration header picked up by tb_mult32.v (`TB_CFG_INC).
{
    echo "\`define DUT $DUT"
    echo "\`define SIGNED_MODE $SM"
    echo "\`define PIPE_STAGES $PS"
    [[ -n "$EXTRA" ]] && echo "\`define DUT_EXTRA_PARAMS $EXTRA"
} > "$BUILD/tb_cfg.vh"

NSRCS=()
for f in "${SRCS[@]}"; do NSRCS+=("$(native "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")")"); done

# Plusargs go through an options file: the .bat wrappers on Windows split
# command-line arguments at '=', which breaks "-testplusarg VECFILE=...".
{
    echo "-testplusarg \"VECFILE=$(native "$VEC")\""
    for pa in "${PLUSARGS[@]+"${PLUSARGS[@]}"}"; do echo "-testplusarg ${pa#+}"; done
} > "$BUILD/xsim_args.txt"

cd "$BUILD"
{
    echo "== sim.sh: DUT=$DUT SIGNED_MODE=$SM PIPE_STAGES=$PS EXTRA='$EXTRA'"
    echo "== vectors: $VEC   plusargs: ${PLUSARGS[*]+"${PLUSARGS[*]}"}"
} | tee sim.log

"$XVLOG" -d TB_CFG_INC "${DEFS[@]+"${DEFS[@]}"}" -i . "${NSRCS[@]}" "$(native "$ROOT/tb/tb_mult32.v")" >> sim.log 2>&1 \
    || { tail -30 sim.log; echo "sim.sh: xvlog failed" >&2; exit 1; }
"$XELAB" -O3 -debug off tb_mult32 -s snap >> sim.log 2>&1 \
    || { tail -30 sim.log; echo "sim.sh: xelab failed" >&2; exit 1; }
"$XSIM" snap -R -f xsim_args.txt >> sim.log 2>&1 || true

# Print the testbench output only (summary and any error lines).
sed -n '/MISMATCH\|ERROR\|FATAL\|tb_mult32 summary/,$p' sim.log | grep -v '^INFO\|^\$finish\|^Time:\|^exit$' | head -60
grep -q '^RESULT: PASS' sim.log
