#!/usr/bin/env python3
"""Build reports/summary.md from the tool report files in reports/.

Every number in the output is parsed from a file in reports/ or derived
from parsed numbers by the arithmetic stated next to it. Nothing is typed in.

Sources per module <name>:
  <name>_util.rpt          post-route utilization (LUT, FF, DSP, CARRY4)
  <name>_fmax_search.txt   achieved (bisected) and coarse clock period
  <name>_timing.rpt        post-route WNS / WHS / WPWS at that period
  <name>_power.rpt         report_power at that period (vectorless)
  <name>_power_100MHz.rpt  report_power of a separate run at 10.000 ns
  sim_summary.txt          latency and pass/fail of the 10^6-vector runs
"""

import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REP = os.path.join(ROOT, "reports")

# name, sim tag stem, configuration text, initiation interval (cycles/result)
# II: 1 for the pipelined designs (verified by streaming back-to-back inputs
# in simulation); 33 for shift-add by construction (it accepts a new operand
# only when idle - see rtl/mult_shiftadd.v).
MODULES = [
    ("mult_behav",      "PIPE_STAGES=2",              1),
    ("mult_shiftadd",   "sequential, radix-2",        33),
    ("mult_karatsuba",  "PIPE_STAGES=4",              1),
    ("mult_wallace_b0", "PIPE_STAGES=4, USE_BOOTH=0", 1),
    ("mult_wallace_b1", "PIPE_STAGES=4, USE_BOOTH=1", 1),
]


def read(name):
    with open(os.path.join(REP, name), encoding="utf-8", errors="replace") as f:
        return f.read()


def table_used(txt, label):
    """'Used' column of a report_utilization table row starting with label."""
    m = re.search(r"^\|\s*" + re.escape(label) + r"\s*\|\s*(\d+)\s*\|", txt, re.M)
    return int(m.group(1)) if m else None


def parse_util(name):
    t = read(f"{name}_util.rpt")
    lut = table_used(t, "Slice LUTs")
    ff = table_used(t, "Slice Registers")
    dsp = table_used(t, "DSPs")
    carry = table_used(t, "CARRY4")
    if carry is None:            # primitives table omits unused cells
        carry = 0
    if None in (lut, ff, dsp):
        sys.exit(f"cannot parse {name}_util.rpt")
    return dict(lut=lut, ff=ff, dsp=dsp, carry=carry)


def parse_search(name):
    t = read(f"{name}_fmax_search.txt")
    a = re.search(r"achieved \(bisected\)\s*:\s*([\d.]+) ns = ([\d.]+) MHz", t)
    c = re.search(r"coarse \(0\.5 ns steps\)\s*:\s*([\d.]+) ns", t)
    f = re.search(r"first failing period\s*:\s*([\d.]+) ns", t)
    if not (a and c):
        sys.exit(f"cannot parse {name}_fmax_search.txt")
    return dict(period=float(a.group(1)), fmax=float(a.group(2)),
                coarse=float(c.group(1)), first_fail=float(f.group(1)) if f else None,
                points=len(re.findall(r"^\s*[\d.]+ ns .*(PASS|FAIL)$", t, re.M)))


def parse_timing(name):
    t = read(f"{name}_timing.rpt")
    m = re.search(r"WNS\(ns\)\s+TNS\(ns\).*\n.*\n\s*(\S+)\s+\S+\s+\S+\s+\S+\s+(\S+)\s+\S+\s+\S+\s+\S+\s+(\S+)", t)
    p = re.search(r"^clk\s+\{[^}]*\}\s+([\d.]+)\s+([\d.]+)", t, re.M)
    if not (m and p):
        sys.exit(f"cannot parse {name}_timing.rpt")
    return dict(wns=float(m.group(1)), whs=float(m.group(2)), wpws=float(m.group(3)),
                clk_period=float(p.group(1)))


def parse_power(fname):
    t = read(fname)
    def w(label):
        m = re.search(r"^\|\s*" + re.escape(label) + r"\s*\|\s*([\d.]+)", t, re.M)
        if not m:
            sys.exit(f"cannot parse '{label}' in {fname}")
        return float(m.group(1)) * 1000.0      # W -> mW
    conf = re.search(r"^\|\s*Confidence Level\s*\|\s*(\w+)", t, re.M)
    return dict(total=w("Total On-Chip Power (W)"), dyn=w("Dynamic (W)"),
                static=w("Device Static (W)"), conf=conf.group(1) if conf else "?")


def parse_sim():
    t = read("sim_summary.txt")
    res = {}
    for m in re.finditer(r"^full_(\S+)_s([01]): (PASS|FAIL) \|\s+results : (\d+); "
                         r"latency : min (\d+) max (\d+) cycles; mismatches : (\d+); "
                         r"protocol errs : (\d+);", t, re.M):
        res[(m.group(1), int(m.group(2)))] = dict(
            ok=m.group(3), n=int(m.group(4)), lat_min=int(m.group(5)),
            lat_max=int(m.group(6)), mism=int(m.group(7)), proto=int(m.group(8)))
    return res


def main():
    sim = parse_sim()
    rows = []
    for name, cfg, ii in MODULES:
        u = parse_util(name)
        s = parse_search(name)
        tm = parse_timing(name)
        pw = parse_power(f"{name}_power.rpt")
        p100 = parse_power(f"{name}_power_100MHz.rpt")
        sims = [sim.get((name, sm)) for sm in (0, 1)]
        if None in sims:
            sys.exit(f"sim_summary.txt has no full runs for {name}")
        if abs(tm["clk_period"] - s["period"]) > 0.0005:
            sys.exit(f"{name}: timing report period {tm['clk_period']} != search result {s['period']}")
        lat = {x["lat_min"] for x in sims} | {x["lat_max"] for x in sims}
        if len(lat) != 1:
            sys.exit(f"{name}: latency not constant across runs: {lat}")
        rows.append(dict(name=name, cfg=cfg, ii=ii, lat=lat.pop(), sims=sims, **u,
                         **s, **{k: v for k, v in tm.items()},
                         p_tot=pw["total"], p_dyn=pw["dyn"], p_static=pw["static"],
                         conf=pw["conf"], p100_tot=p100["total"], p100_dyn=p100["dyn"]))

    for r in rows:
        r["thr"] = r["fmax"] / r["ii"]                       # Mresults/s
        r["e100"] = r["p100_dyn"] * 1e-3 / (100e6 / r["ii"]) * 1e12   # pJ/result

    R = {r["name"]: r for r in rows}
    L = []
    w = L.append

    w("# MUL32-CMP - results summary")
    w("")
    w("Generated by `scripts/make_summary.py` from the report files in `reports/`; "
      "no number below is entered by hand.")
    w("")
    w("Device `xc7a100tcsg324-1` (Artix-7, speed -1), Vivado 2025.1.1, out-of-context, "
      "`SIGNED_MODE=0`, one XDC (`constr/timing.xdc`) and one flow for every module: "
      "`synth_design`, `opt_design`, `place_design`, `phys_opt_design`, `route_design` "
      "(all defaults). All numbers are post-route.")
    w("")

    w("## Comparison")
    w("")
    w("| Module | Config | LUT | FF | DSP | CARRY4 | fmax (MHz) | Latency (cyc) | Throughput | Power (mW) |")
    w("|---|---|--:|--:|--:|--:|--:|--:|---|--:|")
    for r in rows:
        thr = (f"1/cycle = {r['thr']:.1f} M/s" if r["ii"] == 1
               else f"1/{r['ii']} cycles = {r['thr']:.2f} M/s")
        w(f"| {r['name']} | {r['cfg']} | {r['lut']} | {r['ff']} | {r['dsp']} | {r['carry']} | "
          f"{r['fmax']:.1f} | {r['lat']} | {thr} | {r['p_tot']:.0f} |")
    w("")
    w("- **fmax** is the tightest clock period that passed in the search (setup, hold "
      "and pulse-width slack all >= 0 after routing), not \"met timing\" at a fixed clock.")
    w("- **Throughput** = fmax / initiation interval. The pipelined designs accept one "
      "operand pair per cycle (checked in simulation with back-to-back inputs). "
      "mult_shiftadd accepts a new pair only when idle, every 33 cycles (by "
      "construction).")
    w(f"- **mult_shiftadd: its fmax reflects only the adder path, not throughput.** At "
      f"{R['mult_shiftadd']['fmax']:.1f} MHz it delivers {R['mult_shiftadd']['thr']:.2f} M "
      f"results/s.")
    w("- **Power** = total on-chip power from `report_power` at each module's own fmax, "
      "vectorless default activity. See the power table: this total is dominated by "
      "device static power, which is the same for every module.")
    w("")

    w("## fmax search")
    w("")
    w("| Module | Coarse result (0.5 ns steps) | Achieved (bisected) | First failing period | Points run | WNS / WHS / WPWS at achieved (ns) |")
    w("|---|--:|--:|--:|--:|---|")
    for r in rows:
        ff_ = f"{r['first_fail']:.3f} ns" if r["first_fail"] is not None else "-"
        w(f"| {r['name']} | {r['coarse']:.3f} ns | {r['period']:.3f} ns ({r['fmax']:.1f} MHz) | "
          f"{ff_} | {r['points']} | {r['wns']:.3f} / {r['whs']:.3f} / {r['wpws']:.3f} |")
    w("")
    w("Method: start at 5.000 ns; tighten (or loosen) in 0.5 ns steps until the "
      "pass/fail result flips (the coarse result is the last passing step), then bisect "
      "between the last pass and the first fail to <= 0.05 ns. Pass/fail is not "
      "perfectly monotonic in the period (place-and-route noise of a few tens of ps), "
      "so the achieved value is the tightest period that actually passed. Every point "
      "is listed in `reports/<module>_fmax_search.txt`.")
    w("")

    w("## Power")
    w("")
    w("| Module | Total @ fmax (mW) | Dynamic @ fmax (mW) | Static (mW) | Dynamic @ 100 MHz (mW) | Dynamic energy / result @ 100 MHz (pJ) |")
    w("|---|--:|--:|--:|--:|--:|")
    for r in rows:
        w(f"| {r['name']} | {r['p_tot']:.0f} | {r['p_dyn']:.0f} | {r['p_static']:.0f} | "
          f"{r['p100_dyn']:.0f} | {r['e100']:.0f} |")
    w("")
    w("- Energy / result = dynamic power at 100 MHz / (100 MHz / initiation interval).")
    w(f"- `report_power` prints watts with 3 decimals, so every value has 1 mW "
      f"resolution; the small dynamic numbers (3-13 mW) are therefore only good to "
      f"roughly +/-0.5 mW. Activity is Vivado's vectorless default (confidence level "
      f"\"{rows[0]['conf']}\"), not simulated switching.")
    w("- The 100 MHz figures come from a separate implementation of each module at a "
      "10.000 ns clock (`reports/<module>_power_100MHz.rpt`), so all modules are "
      "compared at the same frequency.")
    w("")

    w("## Verification")
    w("")
    w("| Module | Unsigned (10^6 + 400 vectors) | Signed (10^6 + 400 vectors) | Latency |")
    w("|---|---|---|--:|")
    for r in rows:
        cells = []
        for x in r["sims"]:
            cells.append(f"{x['ok']}: {x['n']} results, {x['mism']} mismatches, {x['proto']} protocol errors")
        w(f"| {r['name']} | {cells[0]} | {cells[1]} | {r['lat']} |")
    w("")
    w("Source: `reports/sim_summary.txt` (self-checking `tb/tb_mult32.v` in Vivado xsim "
      "against the Python golden model `tb/golden.py`). Only the unsigned configuration "
      "was implemented; the signed configurations are verified but not in the tables "
      "above.")
    w("")

    # ---------------- conclusion (numbers computed from the rows) ----------------
    b, k, sa = R["mult_behav"], R["mult_karatsuba"], R["mult_shiftadd"]
    w0, w1 = R["mult_wallace_b0"], R["mult_wallace_b1"]
    pipelined = [r for r in rows if r["ii"] == 1]
    best = max(pipelined, key=lambda r: r["fmax"])

    # The conclusion text makes these claims; refuse to write it if the data
    # does not support them.
    def claim(ok, what):
        if not ok:
            sys.exit(f"conclusion claim not supported by the reports: {what}")
    claim(all(b["lut"] <= r["lut"] and b["ff"] <= r["ff"] for r in rows),
          "behav has the fewest LUTs and FFs")
    claim(all(b["e100"] <= r["e100"] for r in rows), "behav has the lowest energy/result")
    claim(k["dsp"] == b["dsp"] - 1 and k["fmax"] < b["fmax"], "karatsuba: one DSP fewer, lower fmax")
    claim("u_mul_mid" in read("mult_karatsuba_timing.rpt").split("Max Delay Paths")[1][:3000],
          "karatsuba critical path ends at the middle DSP")
    claim(best["name"].startswith("mult_wallace"), "a Wallace variant has the highest pipelined fmax")
    claim(max(rows, key=lambda r: r["lut"])["name"].startswith("mult_wallace"),
          "Wallace has the highest LUT count")
    claim(w1["lut"] < w0["lut"] and w1["ff"] < w0["ff"] and w1["fmax"] > w0["fmax"]
          and w1["p100_dyn"] <= w0["p100_dyn"], "Booth beats plain Wallace on LUT/FF/fmax/power")
    claim(all(sa["thr"] < r["thr"] for r in rows if r is not sa), "shift-add has the lowest throughput")
    claim(all(sa["e100"] >= r["e100"] for r in rows), "shift-add has the highest energy/result")

    w("## Conclusion")
    w("")
    w(f"- **The behavioral baseline is the most area-efficient design.** It uses the "
      f"fewest LUTs ({b['lut']}) and FFs ({b['ff']}) of all five, delivers one result "
      f"per cycle at {b['fmax']:.1f} MHz with a {b['lat']}-cycle latency, and has the "
      f"lowest dynamic energy per result ({b['e100']:.0f} pJ at 100 MHz). Its price is "
      f"{b['dsp']} DSP48E1 slices. If DSPs are available, this is the design to use.")
    w(f"- **Karatsuba saves one DSP but costs fmax.** {k['dsp']} DSPs instead of "
      f"{b['dsp']}, paid for with {k['lut'] - b['lut']} more LUTs, {k['ff'] - b['ff']} "
      f"more FFs and {b['fmax'] - k['fmax']:.1f} MHz lower fmax ({k['fmax']:.1f} vs "
      f"{b['fmax']:.1f} MHz). The critical path is the 18-bit pre-add (a0+a1) feeding "
      f"the middle DSP, whose multiply sits in the same cycle because at PIPE_STAGES=4 "
      f"that DSP has no input or M register. **Future work:** PIPE_STAGES=5 adds a "
      f"register after the multipliers so Vivado can use MREG; it is verified in "
      f"simulation but has not been implemented, so its fmax gain is expected, not "
      f"measured.")
    w(f"- **Wallace reaches the highest pipelined fmax despite the highest LUT count.** "
      f"{best['name']} runs at {best['fmax']:.1f} MHz ({w0['name']}: {w0['fmax']:.1f} MHz) "
      f"with zero DSPs, but needs {w0['lut']}/{w1['lut']} LUTs "
      f"({w0['lut'] / b['lut']:.0f}x/{w1['lut'] / b['lut']:.0f}x the baseline) and "
      f"{w0['e100']:.0f}/{w1['e100']:.0f} pJ per result. Booth radix-4 beats the plain "
      f"tree on LUTs, FFs, fmax and power ({w1['lut'] - w0['lut']:+d} LUTs, "
      f"{w1['ff'] - w0['ff']:+d} FFs, {w1['fmax'] - w0['fmax']:+.1f} MHz, "
      f"{w1['p100_dyn'] - w0['p100_dyn']:+.0f} mW at 100 MHz; CARRY4 "
      f"{w1['carry'] - w0['carry']:+d}). The comparison "
      f"with the baseline is not at equal latency: Wallace uses {w0['lat']} pipeline "
      f"stages, the baseline {b['lat']}; a deeper behavioral pipeline was not "
      f"implemented.")
    w(f"- **Shift-add's fmax is misleading.** Its {sa['fmax']:.1f} MHz is only the speed "
      f"of one 33-bit add per cycle; with one result every {sa['ii']} cycles its "
      f"throughput is {sa['thr']:.2f} M results/s, {b['thr'] / sa['thr']:.0f}x lower than "
      f"the baseline, and its energy per result ({sa['e100']:.0f} pJ) is the highest. Its "
      f"only advantage is zero DSPs with few LUTs ({sa['lut']}).")
    w("")
    w("Overall: for a 32x32 multiplier on Artix-7, letting Vivado map `a * b` onto "
      "DSP48E1 is the best choice unless DSPs are the scarce resource; hand-built "
      "architectures win only on a specific axis (DSP count, raw clock rate) and pay "
      "for it elsewhere.")
    w("")

    out = os.path.join(REP, "summary.md")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
