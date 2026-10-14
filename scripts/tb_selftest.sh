#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# tb_selftest.sh - prove tb_mult32 accepts a correct DUT and rejects broken
# ones, using the testbench-only model tb/tb_ref_mult.v (mult_tbref).
#
#   scripts/tb_selftest.sh          smoke vectors only
#   scripts/tb_selftest.sh --full   also run the 10^6-vector sets
# ----------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/scripts/sim.sh"
REF="$ROOT/tb/tb_ref_mult.v"
VEC="$ROOT/vectors"
fails=0

# expect <PASS|FAIL> <log pattern required on FAIL> <tag> <sim.sh args...>
expect() {
    local want="$1" pat="$2" tag="$3"; shift 3
    local got log="$ROOT/build/sim/st_$tag/sim.log"
    if "$SIM" -m mult_tbref -f "$REF" -t "st_$tag" "$@" >/dev/null 2>&1; then got=PASS; else got=FAIL; fi
    local ok=1
    [[ "$got" == "$want" ]] || ok=0
    if [[ "$want" == FAIL && $ok == 1 ]] && ! grep -q "$pat" "$log"; then ok=0; fi
    local summ; summ=$(grep -E "^ +(results|mismatches|protocol errs) " "$log" 2>/dev/null | tr -s ' ' | tr '\n' ';')
    if [[ $ok == 1 ]]; then printf "  ok    %-22s expect %-4s got %-4s %s\n" "$tag" "$want" "$got" "$summ"
    else printf "  BAD   %-22s expect %-4s got %-4s %s\n" "$tag" "$want" "$got" "$summ"; fails=$((fails+1)); fi
}

echo "== positive cases (correct model must PASS)"
expect PASS "" u_p2_stream        -s 0 -p 2 -- +LATENCY=2
expect PASS "" s_p2_stream        -s 1 -p 2 -- +LATENCY=2
expect PASS "" s_p0_comb          -s 1 -p 0 -- +LATENCY=0
expect PASS "" s_p5_b2b           -s 1 -p 5 -- +LATENCY=5 +BUBBLE=0
expect PASS "" u_p7_bubble50      -s 0 -p 7 -- +BUBBLE=50 +SEED=7
expect PASS "" u_p3_wait          -s 0 -p 3 -- +WAIT +LATENCY=3
expect PASS "" s_p1_wait          -s 1 -p 1 -- +WAIT
expect PASS "" s_maxvec400        -s 1 -p 2 -- +MAXVEC=400

echo "== negative cases (broken model / wrong setup must FAIL for the right reason)"
expect FAIL "MISMATCH"                 f1_bitflip   -s 1 -p 2 -x ".FAULT(1)"
expect FAIL "MISMATCH"                 f2_unsigned  -s 1 -p 2 -x ".FAULT(2)"
expect FAIL "MISMATCH\|latency"        f3_dropvalid -s 0 -p 2 -x ".FAULT(3)"
expect FAIL "latency 3, expected 2"    f4_latjit    -s 0 -p 2 -x ".FAULT(4)" -- +LATENCY=2
expect FAIL "latency 3, first vector"  f4_latjit_nl -s 0 -p 2 -x ".FAULT(4)"
expect FAIL "no outstanding input"     f5_spurious  -s 0 -p 2 -x ".FAULT(5)"
expect FAIL "no result for input #0"   f6_novalid   -s 0 -p 2 -x ".FAULT(6)" -- +TIMEOUT=200
expect FAIL "MISMATCH"                 wrong_sign   -s 0 -p 2 -v "$VEC/vec_signed_smoke.hex"
expect FAIL "latency 2, expected 3"    wrong_lat    -s 1 -p 2 -- +LATENCY=3

if [[ "${1:-}" == "--full" ]]; then
    echo "== full 10^6-vector sets"
    expect PASS "" full_s_p2      -s 1 -p 2 -v "$VEC/vec_signed.hex"   -- +LATENCY=2
    expect PASS "" full_u_p2      -s 0 -p 2 -v "$VEC/vec_unsigned.hex" -- +LATENCY=2
fi

echo
if [[ $fails == 0 ]]; then echo "TB SELF-TEST: PASS"; else echo "TB SELF-TEST: FAIL ($fails cases)"; fi
exit $(( fails > 0 ))
