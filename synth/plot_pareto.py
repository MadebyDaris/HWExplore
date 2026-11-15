#!/usr/bin/env python3
"""synth/plot_pareto.py

Plot a DotGen Pareto exploration CSV (examples/pareto_mxfp8_dot.jl):
left, area vs accuracy with the area/error Pareto front; right, area vs delay,
ringing the designs on the 3-objective front. Writes <csv>.png next to the CSV.

Usage: python3 synth/plot_pareto.py synth/results/pareto_mxfp8_dot.csv
"""
import csv
import math
import pathlib
import sys

import matplotlib.pyplot as plt

SERIES = {"csa": ("#2a78d6", "3:2 carry-save tree"), "adder": ("#eb6834", "adder tree")}
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "synth/results/pareto_mxfp8_dot.csv")
rows = list(csv.DictReader(open(path)))
for r in rows:
    r["area"] = float(r["area_um2"]) / 1000
    r["delay"] = float(r["delay_ps"]) / 1000
    r["err"] = math.log2(float(r["mean_err_outliers"]))
    r["f2"] = r["front_area_err"] == "true"
    r["f3"] = r["front_area_delay_err"] == "true"

plt.rcParams.update({"font.size": 9, "axes.edgecolor": INK2, "axes.labelcolor": INK,
                     "xtick.color": INK2, "ytick.color": INK2, "font.family": "sans-serif"})
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.4), facecolor=SURFACE)


def style(ax):
    ax.set_facecolor(SURFACE)
    ax.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)


# Left: cost vs accuracy, with the 2-objective front as a step line.
style(ax1)
front = sorted((r for r in rows if r["f2"]), key=lambda r: r["area"])
ax1.step([r["area"] for r in front], [r["err"] for r in front], where="post",
         color=INK2, linewidth=1.5, zorder=1, label="Pareto front (area, error)")
for tree, (color, name) in SERIES.items():
    pts = [r for r in rows if r["tree"] == tree]
    ax1.scatter([r["area"] for r in pts], [r["err"] for r in pts], s=46, color=color,
                edgecolors=SURFACE, linewidths=2, zorder=3, label=name)
for r in front:
    ax1.annotate(f"W={r['window']}", (r["area"], r["err"]), textcoords="offset points",
                 xytext=(6, 4), fontsize=8, color=INK)
ax1.set_xlabel("Cell area, SG13G2 (×1000 µm²)")
ax1.set_ylabel("Mean error, log₂ of |hw − exact| / Σ|aᵢbᵢ|")
ax1.set_title("Cost vs accuracy (lower-left is better)", color=INK, loc="left", fontsize=10)
ax1.legend(frameon=False, fontsize=8, loc="upper right")

# Right: cost vs speed; ring the points on the 3-objective front.
style(ax2)
for tree, (color, name) in SERIES.items():
    pts = [r for r in rows if r["tree"] == tree]
    ax2.scatter([r["area"] for r in pts], [r["delay"] for r in pts], s=46, color=color,
                edgecolors=SURFACE, linewidths=2, zorder=3, label=name)
f3 = [r for r in rows if r["f3"]]
ax2.scatter([r["area"] for r in f3], [r["delay"] for r in f3], s=150, facecolors="none",
            edgecolors=INK, linewidths=1.2, zorder=2, label="on 3-objective front")
for r in rows:
    if r["tree"] == "csa":
        ax2.annotate(r["window"], (r["area"], r["delay"]), textcoords="offset points",
                     xytext=(5, -10), fontsize=7, color=INK2)
fastest = min(rows, key=lambda r: r["delay"])
ax2.annotate(f"W={fastest['window']}, {fastest['tree']} tree: fastest", (fastest["area"], fastest["delay"]),
             textcoords="offset points", xytext=(-12, -3), ha="right", fontsize=8, color=INK)
ax2.set_xlabel("Cell area, SG13G2 (×1000 µm²)")
ax2.set_ylabel("Critical path, logic only (ns)")
ax2.set_title("Cost vs speed (labels: window W, CSA designs)", color=INK, loc="left", fontsize=10)
ax2.legend(frameon=False, fontsize=8, loc="lower left")

fig.suptitle("MXFP8 × MXFP8 dot product, K = 32, FP32 out: design space", x=0.01, ha="left",
             color=INK, fontsize=11)
fig.tight_layout()
out = path.with_suffix(".png")
fig.savefig(out, dpi=160, facecolor=SURFACE)
print(f"wrote {out}")
