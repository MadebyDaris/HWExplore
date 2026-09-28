#!/usr/bin/env python3
"""synth/plot_results.py

Tiny bar chart of synth/results/summary.csv (Sky130 chip area per design),
for dropping into the README. Nothing fancy -- one plot, one file.

Usage: python3 plot_results.py
"""
import csv
import pathlib

import matplotlib.pyplot as plt

HERE = pathlib.Path(__file__).parent
rows = list(csv.DictReader(open(HERE / "results" / "summary.csv")))

names = [r["design"] for r in rows]
areas = [float(r["area_um2"]) for r in rows]

# Highlight the resource-sharing sweep (same design, 4/2/1 shared multipliers)
# in one color, everything else in another.
shared = [n.startswith("vector_dot4_share") for n in names]
colors = ["#4C72B0" if s else "#8C8C8C" for s in shared]

fig, ax = plt.subplots(figsize=(7, 4))
bars = ax.bar(names, areas, color=colors)
ax.set_ylabel("Chip area (µm²), Sky130 sky130_fd_sc_lp")
ax.set_title("Yosys+ABC synthesis: generated datapaths")
ax.tick_params(axis="x", rotation=30)
for bar, area in zip(bars, areas):
    ax.annotate(f"{area/1000:.1f}k", (bar.get_x() + bar.get_width() / 2, area),
                ha="center", va="bottom", fontsize=8)
fig.tight_layout()
out = HERE / "results" / "area_chart.png"
fig.savefig(out, dpi=150)
print(f"wrote {out}")
