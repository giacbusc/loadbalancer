#!/usr/bin/env python3
"""
Generate a figure similar to Figure 6 of the Prequal paper
(Load ramp experiment: tail latency comparison between RR and Prequal)
"""

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.ticker as ticker
import numpy as np

# ── Load data ──────────────────────────────────────────────────────────────────
df = pd.read_csv("results-20260519-100906/summary.csv")

# Parse load level as integer
df["load"] = df["level"].str.replace("pct", "").astype(int)

# Keep native μs — no conversion needed; the formatter below adds the unit label.
# (Converting to ms would add a spurious ×1000 transformation to data that hey
#  already delivers in seconds and we stored as μs in the CSV.)

rr     = df[df["algorithm"] == "rr"    ].sort_values("load")
prequal = df[df["algorithm"] == "prequal"].sort_values("load")

# ── Figure layout: 2 subplots (latency + throughput) ──────────────────────────
fig, (ax1, ax2) = plt.subplots(
    2, 1,
    figsize=(9, 8),
    gridspec_kw={"height_ratios": [3, 1.4]},
)
fig.suptitle("Load Ramp Experiment — Prequal vs Round Robin\n(Figure 6, section 5.1, Load is not what you should balance 2024)",
             fontsize=13, fontweight="bold", y=0.98)

load_ticks = sorted(df["load"].unique())
x_labels   = [f"{v}%" for v in load_ticks]

# ── Colours ──
COLOR_RR      = "#d62728"   # red family  → WRR in the paper uses red/orange
COLOR_PREQUAL = "#1f77b4"   # blue family → Prequal uses blue/teal

ALPHA_LIGHT = 0.35
LW = 2.0

# ── (a) Tail latency – log scale ──────────────────────────────────────────────
ax1.set_yscale("log")

# RR lines
ax1.plot(rr["load"], rr["p50_us"], color=COLOR_RR,  lw=LW,       linestyle="--",
         label="RR  p50",  marker="o", markersize=5)
ax1.plot(rr["load"], rr["p90_us"], color=COLOR_RR,  lw=LW,       linestyle="-.",
         label="RR  p90",  marker="s", markersize=5)
ax1.plot(rr["load"], rr["p99_us"], color=COLOR_RR,  lw=LW+0.5,   linestyle="-",
         label="RR  p99",  marker="^", markersize=6)

# Prequal lines
ax1.plot(prequal["load"], prequal["p50_us"], color=COLOR_PREQUAL, lw=LW,     linestyle="--",
         label="Prequal p50", marker="o", markersize=5)
ax1.plot(prequal["load"], prequal["p90_us"], color=COLOR_PREQUAL, lw=LW,     linestyle="-.",
         label="Prequal p90", marker="s", markersize=5)
ax1.plot(prequal["load"], prequal["p99_us"], color=COLOR_PREQUAL, lw=LW+0.5, linestyle="-",
         label="Prequal p99", marker="^", markersize=6)

# Shade "above allocation" region
ax1.axvspan(100, max(load_ticks) + 5, color="lightyellow", alpha=0.6, zorder=0)
ax1.axvline(x=100, color="gray", linestyle=":", lw=1.4, zorder=1)
ax1.text(100.8, ax1.get_ylim()[0] * 1.5, "← Below Alloc  |  Above Alloc →",
         fontsize=8, color="gray", va="bottom")

ax1.set_ylabel("Latency (us, log scale)", fontsize=11)
ax1.set_title("(a) Tail Latency", fontsize=11, loc="left")
ax1.set_xticks(load_ticks)
ax1.set_xticklabels(x_labels, fontsize=9)

# Clean formatter: keep us as native unit (same as the paper: "measured in
# microseconds"). Each major gridline = 10x the previous one.
# Display human-readable labels: 100ms, 1s, etc.
def us_formatter(y, _):
    if y >= 1_000_000:
        return f"{int(y/1_000_000)}s"
    if y >= 1_000:
        return f"{int(y/1_000)}ms"
    return f"{int(y)}us"

# Explicit ticks covering our data range (300_000us=300ms ... 5_000_000us=5s).
# Each step is roughly 3x or 10x — readable on a log axis.
y_ticks = [100_000, 300_000, 1_000_000, 3_000_000, 5_000_000]
ax1.set_yticks(y_ticks)
ax1.yaxis.set_major_formatter(ticker.FuncFormatter(us_formatter))
ax1.yaxis.set_minor_formatter(ticker.NullFormatter())
ax1.set_ylim(150_000, 6_500_000)
ax1.grid(True, which="major", linestyle="--", alpha=0.4)
ax1.legend(fontsize=8.5, ncol=2, loc="upper left", framealpha=0.9)

# Annotate the allocation boundary
ax1.annotate("100%\nallocation", xy=(100, ax1.get_ylim()[1]*0.6),
             fontsize=8, color="gray", ha="center")

# ── (b) Throughput (QPS) ──────────────────────────────────────────────────────
bar_w = 3.5
offsets = np.array(load_ticks)

ax2.bar(offsets - bar_w/2, rr["qps"].values,     width=bar_w, color=COLOR_RR,
        alpha=0.75, label="Round Robin")
ax2.bar(offsets + bar_w/2, prequal["qps"].values, width=bar_w, color=COLOR_PREQUAL,
        alpha=0.75, label="Prequal")

ax2.axvspan(100, max(load_ticks) + 5, color="lightyellow", alpha=0.6, zorder=0)
ax2.axvline(x=100, color="gray", linestyle=":", lw=1.4, zorder=1)

ax2.set_ylabel("Throughput (QPS)", fontsize=11)
ax2.set_title("(b) Achieved Throughput", fontsize=11, loc="left")
ax2.set_xticks(load_ticks)
ax2.set_xticklabels(x_labels, fontsize=9)
ax2.set_xlabel("Load (% of server allocation)", fontsize=11)
ax2.grid(True, axis="y", linestyle="--", alpha=0.4)
ax2.legend(fontsize=9, loc="upper left", framealpha=0.9)

# Add % improvement annotations at overload points
for _, row_rr in rr[rr["load"] >= 100].iterrows():
    load = row_rr["load"]
    row_p = prequal[prequal["load"] == load].iloc[0]
    diff_pct = (row_p["qps"] - row_rr["qps"]) / row_rr["qps"] * 100
    if diff_pct > 1:
        ax2.text(load, max(row_p["qps"], row_rr["qps"]) + 4,
                 f"+{diff_pct:.0f}%", ha="center", va="bottom",
                 fontsize=7, color=COLOR_PREQUAL, fontweight="bold")

plt.tight_layout(rect=[0, 0, 1, 0.96])

out_path = "results-20260519-100906/figure6_comparison.png"
plt.savefig(out_path, dpi=150, bbox_inches="tight")
print(f"Saved → {out_path}")
plt.close()
