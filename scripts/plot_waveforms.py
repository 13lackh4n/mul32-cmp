#!/usr/bin/env python3
"""Simulate each multiplier with a VCD dump and plot the first clock cycles.

For each of the 5 configurations (SIGNED_MODE=0, smoke vectors):
  1. scripts/sim.sh with the DUMP_VCD define (xvlog -d DUMP_VCD, the xsim
     equivalent of +define+DUMP_VCD) -> build/vcd/<name>.vcd
  2. parse the VCD (small built-in parser, no python-vcd needed)
  3. plot clk, rst_n, valid_in, a, b, p, valid_out in a Vivado-like style
     (black background, green traces, red for X)
  4. save schematics/<name>_wave.png at 150 DPI

Runs strictly sequentially. Needs matplotlib, e.g.

    py -3.11 scripts/plot_waveforms.py

Only the first CYCLES clock cycles (from time 0, reset included) are plotted.
"""

import os
import re
import shutil
import subprocess
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt           # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CLK_NS = 10.0                              # tb_mult32: always #5 clk = ~clk
CYCLES = 100
DUMP_CYCLES = CYCLES + 20                  # dump a little past the plot window
DPI = 150

# name, module, rtl, extra params, PIPE_STAGES, extra plusargs
CONFIGS = [
    ("mult_behav",      "mult_behav",     "rtl/mult_behav.v",     "",              2, []),
    ("mult_shiftadd",   "mult_shiftadd",  "rtl/mult_shiftadd.v",  "",              2, ["+WAIT", "+LATENCY=33"]),
    ("mult_karatsuba",  "mult_karatsuba", "rtl/mult_karatsuba.v", "",              4, []),
    ("mult_wallace_b0", "mult_wallace",   "rtl/mult_wallace.v",   ".USE_BOOTH(0)", 4, []),
    ("mult_wallace_b1", "mult_wallace",   "rtl/mult_wallace.v",   ".USE_BOOTH(1)", 4, []),
]

ORDER = ["clk", "rst_n", "valid_in", "a", "b", "p", "valid_out"]

BG, FG, GRID, XCOL, TXT = "#000000", "#00e000", "#303030", "#ff3030", "#ffffff"


# ----------------------------------------------------------------------------
# Simulation
# ----------------------------------------------------------------------------
def simulate(name, module, rtl, extra, ps, plus):
    bash = shutil.which("bash")
    if bash is None:
        sys.exit("bash not found (needed for scripts/sim.sh)")
    tag = f"vcd_{name}"
    cmd = [bash, "scripts/sim.sh", "-m", module, "-f", rtl, "-s", "0", "-p", str(ps),
           "-t", tag, "-D", "DUMP_VCD"]
    if extra:
        cmd += ["-x", extra]
    lat = [] if any(p.startswith("+LATENCY") for p in plus) else [f"+LATENCY={ps}"]
    cmd += ["--"] + plus + lat + [f"+DUMPCYCLES={DUMP_CYCLES}"]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    status = "PASS" if r.returncode == 0 else "FAIL"
    src = os.path.join(ROOT, "build", "sim", tag, "dump.vcd")
    if not os.path.isfile(src):
        sys.exit(f"{name}: no VCD produced (simulation {status}); see build/sim/{tag}/sim.log")
    dst_dir = os.path.join(ROOT, "build", "vcd")
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, f"{name}.vcd")
    shutil.copyfile(src, dst)
    return dst, status


# ----------------------------------------------------------------------------
# VCD parser (scalars and vectors; stops at $dumpoff)
# ----------------------------------------------------------------------------
def parse_vcd(path):
    scale = {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "ps": 1e-3, "fs": 1e-6}
    with open(path, encoding="ascii", errors="replace") as f:
        txt = f.read()
    head, _, body = txt.partition("$enddefinitions")
    m = re.search(r"\$timescale\s*(\d+)\s*(\w+)\s*\$end", head)
    ts_ns = int(m.group(1)) * scale[m.group(2)] if m else 1e-3
    sigs = {}                                  # id -> (name, width)
    for v in re.finditer(r"\$var\s+\w+\s+(\d+)\s+(\S+)\s+(\S+)", head):
        sigs[v.group(2)] = (v.group(3), int(v.group(1)))
    waves = {nm: [] for nm, _ in sigs.values()}
    t = 0.0
    toks = body.split()
    i = 1                                      # skip the "$end" of $enddefinitions
    while i < len(toks):
        tok = toks[i]
        if tok == "$dumpoff":
            break                              # values inside are artificial x
        if tok.startswith("#"):
            t = int(tok[1:]) * ts_ns
        elif tok[0] in "bBrR":
            val, ident = tok[1:], toks[i + 1]
            i += 1
            if ident in sigs:
                nm, w = sigs[ident]
                waves[nm].append((t, val.lower().rjust(w, "0" if val[0] in "01" else val[0].lower())))
        elif tok[0] in "01xXzZ" and len(tok) > 1:
            ident = tok[1:]
            if ident in sigs:
                waves[sigs[ident][0]].append((t, tok[0].lower()))
        i += 1
    return waves, {nm: w for nm, w in sigs.values()}


def segments(changes, t_end):
    """[(t0, t1, value)] with consecutive equal values merged, clipped to t_end."""
    seg = []
    for k, (t, v) in enumerate(changes):
        if t >= t_end:
            break
        t1 = changes[k + 1][0] if k + 1 < len(changes) else t_end
        t1 = min(t1, t_end)
        if seg and seg[-1][2] == v and seg[-1][1] == t:
            seg[-1] = (seg[-1][0], t1, v)
        elif t1 > t:
            seg.append((t, t1, v))
    return seg


def bus_text(bits, width):
    if any(c in "xz" for c in bits):
        return "X" if "x" in bits else "Z"
    return f"{int(bits, 2):0{(width + 3) // 4}x}".upper()


# ----------------------------------------------------------------------------
# Plot
# ----------------------------------------------------------------------------
def plot(name, waves, widths, status, out_png):
    t_end = CYCLES * CLK_NS
    n = len(ORDER)
    fig_w, fig_h = 28.0, 0.62 * n + 1.1
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), dpi=DPI)
    fig.patch.set_facecolor(BG)
    ax.set_facecolor(BG)
    left, right = 0.06, 0.985
    fig.subplots_adjust(left=left, right=right, top=1 - 0.55 / fig_h, bottom=0.6 / fig_h)

    # text fitting: pixels per ns and approximate character width at 6.5 pt
    px_per_ns = fig_w * (right - left) * DPI / t_end
    char_px = 0.62 * 6.5 / 72 * DPI
    ramp = 0.6                                 # ns, bus transition slope

    for c in range(0, CYCLES + 1):             # rising edges at 5 + 10k ns
        ax.axvline(5 + c * CLK_NS, color=GRID, lw=0.4, zorder=0)

    for row, sig in enumerate(ORDER):
        y0 = n - 1 - row                       # first signal at the top
        lo, hi, mid = y0 + 0.2, y0 + 0.8, y0 + 0.5
        ax.text(-0.006, mid, sig, transform=ax.get_yaxis_transform(), ha="right",
                va="center", color=TXT, fontsize=9, family="monospace")
        segs = segments(waves.get(sig, []), t_end)
        w = widths.get(sig, 1)
        for t0, t1, v in segs:
            if w == 1:
                if v in "xz":
                    ax.fill_between([t0, t1], lo, hi, color=XCOL, alpha=0.35, lw=0)
                    ax.plot([t0, t1], [mid, mid], color=XCOL, lw=1.0)
                else:
                    y = hi if v == "1" else lo
                    ax.plot([t0, t1], [y, y], color=FG, lw=1.1)
            else:
                col = XCOL if any(ch in "xz" for ch in v) else FG
                r = min(ramp, (t1 - t0) / 2)
                ax.plot([t0, t0 + r, t1 - r, t1], [mid, hi, hi, mid], color=col, lw=0.9)
                ax.plot([t0, t0 + r, t1 - r, t1], [mid, lo, lo, mid], color=col, lw=0.9)
                txt = bus_text(v, w)
                fit = int(((t1 - t0) - 2 * r) * px_per_ns / char_px)
                if fit >= len(txt):
                    label = txt
                elif fit >= 3:
                    label = txt[:fit - 1] + "…"
                else:
                    label = ""
                if label:
                    ax.text((t0 + t1) / 2, mid, label, ha="center", va="center",
                            color=TXT if col == FG else XCOL, fontsize=6.5, family="monospace")
        # single-bit edges: vertical connectors between levels
        if w == 1:
            for (ta, _, va), (tb, _, vb) in zip(segs, segs[1:]):
                if va in "01" and vb in "01" and va != vb:
                    ax.plot([tb, tb], [lo, hi], color=FG, lw=1.1)

    ax.set_xlim(0, t_end)
    ax.set_ylim(-0.1, n + 0.1)
    ax.set_yticks([])
    ticks = list(range(0, CYCLES + 1, 10))
    ax.set_xticks([c * CLK_NS for c in ticks])
    ax.set_xticklabels([f"{c}\n{c * CLK_NS:.0f} ns" for c in ticks], color=TXT, fontsize=8)
    ax.tick_params(axis="x", colors=TXT, length=3)
    for s in ax.spines.values():
        s.set_color(GRID)
    ax.set_xlabel("clock cycle / simulation time", color=TXT, fontsize=8)
    ax.set_title(f"{name}   (SIGNED_MODE=0, smoke vectors, first {CYCLES} cycles, "
                 f"clk period {CLK_NS:.0f} ns in simulation; testbench result: {status})",
                 color=TXT, fontsize=10, loc="left")
    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    fig.savefig(out_png, dpi=DPI, facecolor=BG)
    plt.close(fig)


def main():
    out_dir = os.path.join(ROOT, "schematics")
    for name, module, rtl, extra, ps, plus in CONFIGS:
        print(f"{name}: simulating ...", flush=True)
        vcd, status = simulate(name, module, rtl, extra, ps, plus)
        waves, widths = parse_vcd(vcd)
        missing = [s for s in ORDER if not waves.get(s)]
        if missing:
            sys.exit(f"{name}: signals missing from VCD: {missing}")
        png = os.path.join(out_dir, f"{name}_wave.png")
        plot(name, waves, widths, status, png)
        print(f"{name}: testbench {status}, VCD {os.path.relpath(vcd, ROOT)}, "
              f"plot {os.path.relpath(png, ROOT)}", flush=True)


if __name__ == "__main__":
    main()
