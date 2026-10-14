# MUL32-CMP — 32-bit multiplier architectures on FPGA

Goal: compare four 32x32 -> 64-bit multiplier architectures on an Artix-7
(`xc7a100tcsg324-1`) by area, achieved fmax, latency, throughput and power,
using one common interface, one testbench, one constraint file and one
Vivado flow.

## What was built

All four modules share the same ports (`clk`, `rst_n`, `valid_in`, `a`, `b`,
`p`, `valid_out`) and the parameters `SIGNED_MODE` (0/1) and `PIPE_STAGES`.

| File | Architecture |
|---|---|
| `rtl/mult_behav.v` | `p = a * b` with input and output registers, `use_dsp = "yes"`; Vivado maps it to 4 DSP48E1. |
| `rtl/mult_shiftadd.v` | Sequential radix-2 shift-and-add, one 33-bit adder. Signed mode uses sign-magnitude with 33-bit intermediates. Latency 33, one operation at a time. |
| `rtl/mult_karatsuba.v` | One Karatsuba level on 16-bit halves: 3 multiplies (17x17, 17x17, 18x18 signed), one DSP48E1 each. |
| `rtl/mult_wallace.v` | Fabric-only (`use_dsp = "no"`) 3:2 carry-save tree plus a 64-bit carry-propagate adder. `USE_BOOTH=0`: 32 AND-gate partial products (modified Baugh-Wooley when signed). `USE_BOOTH=1`: 17 Booth radix-4 partial products. |

Verification: `tb/golden.py` generates 400 directed corner cases plus 10^6
random vectors per signedness mode; `tb/tb_mult32.v` is a self-checking
testbench (in-order scoreboard, exact compare, latency and protocol checks).
The testbench itself is checked against a reference model with injected
faults (`scripts/tb_selftest.sh`).

## How to reproduce

Requirements: Python 3, Vivado 2025.1 (xsim is used for simulation), a bash
shell (on Windows: Git Bash). If Vivado is not in `C:/Xilinx/2025.1.1/Vivado/bin`,
set `VIVADO_BIN` to its `bin` directory.

```sh
# everything, sequentially: vectors -> simulation -> implementation -> summary
scripts/run_all.sh

# or stage by stage
python tb/golden.py                    # vectors/vec_{signed,unsigned}[_smoke].hex
scripts/tb_selftest.sh                 # optional: check the testbench itself
scripts/run_all.sh sim                 # 10 full-vector runs -> reports/sim_summary.txt
scripts/run_all.sh impl                # fmax search per module -> reports/<module>_*.rpt
scripts/run_all.sh summary             # reports/summary.md

# a single simulation, e.g. Booth Wallace, signed, smoke vectors
scripts/sim.sh -m mult_wallace -f rtl/mult_wallace.v -s 1 -p 4 -x ".USE_BOOTH(1)" -- +LATENCY=4
```

Implementation (`scripts/synth.tcl`) runs out-of-context synthesis,
`opt_design`, `place_design`, `phys_opt_design` and `route_design` with default
settings. The clock period is searched: start at 5.000 ns, step 0.5 ns until
pass/fail flips, then bisect to <= 0.05 ns. A period passes when post-route
setup, hold and pulse-width slack are all >= 0. Runtime is about 1 minute per
search point, roughly 1 hour for all modules. Run Vivado jobs one at a time;
parallel launches on the development machine produced spurious tool errors.

## Results

Post-route, `SIGNED_MODE=0`. All numbers come from the report files in
`reports/` (see `reports/summary.md` for the fmax search, power breakdown and
verification tables).

| Module | Config | LUT | FF | DSP | CARRY4 | fmax (MHz) | Latency (cyc) | Throughput | Power (mW) |
|---|---|--:|--:|--:|--:|--:|--:|---|--:|
| mult_behav | PIPE_STAGES=2 | 48 | 83 | 4 | 12 | 197.5 | 2 | 1/cycle = 197.5 M/s | 95 |
| mult_shiftadd | sequential, radix-2 | 105 | 168 | 0 | 9 | 273.4 | 33 | 1/33 cycles = 8.29 M/s | 91 |
| mult_karatsuba | PIPE_STAGES=4 | 117 | 232 | 3 | 32 | 146.1 | 4 | 1/cycle = 146.1 M/s | 97 |
| mult_wallace_b0 | PIPE_STAGES=4, USE_BOOTH=0 | 1584 | 606 | 0 | 14 | 244.3 | 4 | 1/cycle = 244.3 M/s | 181 |
| mult_wallace_b1 | PIPE_STAGES=4, USE_BOOTH=1 | 1259 | 570 | 0 | 15 | 262.3 | 4 | 1/cycle = 262.3 M/s | 175 |

Power is total on-chip power at each module's own fmax; 84 mW of it is device
static power, identical for all modules. Dynamic power at a common 100 MHz
clock is 5 / 3 / 9 / 39 / 34 mW (same row order), i.e. 50 / 990 / 90 / 390 /
340 pJ per result.

All five configurations pass the full vector sets in both signedness modes
(1,000,400 vectors each, 0 mismatches).

## Conclusion

1. **The behavioral baseline wins on area and energy efficiency.** It has the
   fewest LUTs (48) and FFs (83), one result per cycle at 197.5 MHz, and the
   lowest dynamic energy per result (50 pJ). It uses 4 DSP48E1. Unless DSPs are
   the scarce resource, `a * b` is the design to use.
2. **Karatsuba saves one DSP but pays in fmax and energy at PIPE_STAGES=4.**
   3 DSPs instead of 4 cost 69 LUTs, 149 FFs, 51.4 MHz of fmax (146.1 vs
   197.5 MHz) and 90 vs 50 pJ per result. The critical path is the 18-bit
   pre-add feeding the middle DSP, whose multiply has no M register at this
   depth. PIPE_STAGES=5 adds that register and is expected to fix the fmax
   loss; it is verified in simulation but not implemented (future work).
3. **Wallace reaches the highest pipelined fmax at 26-33x the LUT cost.**
   262.3 MHz (Booth) and 244.3 MHz (plain) with zero DSPs, using 1259 / 1584
   LUTs. The Booth variant is better than or equal to the plain tree on every metric except
   CARRY4 (15 vs 14): -325 LUTs, -36 FFs, +18.0 MHz, -5 mW at 100 MHz.
4. **The shift-add fmax is misleading.** 273.4 MHz is the speed of one add per
   cycle; with one result every 33 cycles the throughput is 8.29 M results/s,
   24x below the baseline, at the highest energy per result (990 pJ).

## Limitations

- **Unsigned only in implementation.** Signed mode is verified for every
  module but was synthesized only (`reports/*_s1_synth_util.rpt`), not
  implemented or timed. Signed shift-add needs about 2.3x the LUTs of unsigned.
- **Out-of-context.** No I/O buffers or placement constraints; ports have a
  0 ns input/output delay and are excluded from hold checks. Numbers describe
  the multiplier alone, not a multiplier inside a full design.
- **Vectorless power.** `report_power` with default activity (confidence
  "Medium"), 1 mW resolution; the small dynamic values are good to about
  +/-0.5 mW. No simulated switching activity was used.
- **Pipeline depth not equalized.** The baseline has 2 stages, Karatsuba and
  Wallace 4, shift-add is sequential. Wallace's fmax lead over the baseline is
  therefore not a like-for-like comparison; deeper baseline and Karatsuba
  pipelines were not implemented.
- **fmax resolution.** Pass/fail is not perfectly monotonic in the clock
  period; each fmax is the tightest period that passed, to about 0.03-0.05 ns.
- **One device, one tool version, default strategy only.**
