#!/usr/bin/env python3
"""
plot_shock.py — Risposta transitoria a uno shock correlato (esperimento A).

Legge l'output PER-RICHIESTA di hey (-o csv) delle due passate prequal/rr,
RIPIEGA (folds) tutti i cicli di shock allineandoli all'istante ON, e calcola
la curva di percentile-latenza vs "tempo dallo shock" via ENSEMBLE AVERAGING.
Questo è ciò che rende attendibile la misura del transitorio: un singolo evento
è rumoroso sulla coda, ma mediando N cicli identici la curva p99(t) emerge pulita
(vedi discussione: probing a 250ms << drenaggio code ~2-4s → transitorio risolto
con bin a 0.5s).

Usage:
  python3 plot_shock.py /tmp/results-shock-XXXXX
"""

import sys
import os
import bisect
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# ── Parametri ────────────────────────────────────────────────────────────────
results_dir = sys.argv[1] if len(sys.argv) > 1 else "."
BIN = 0.5   # larghezza bin temporale (s) — ben sopra il periodo di probe (250ms)
MIN_SAMPLES = 20   # bin con meno campioni di così → NaN (non plottato)

COLOR_RR      = "#d62728"   # rosso  (come plot_results.py)
COLOR_PREQUAL = "#1f77b4"   # blu

# ── Metadati dell'esperimento ─────────────────────────────────────────────────
meta = {}
with open(os.path.join(results_dir, "meta.env")) as f:
    for line in f:
        line = line.strip()
        if "=" in line:
            k, v = line.split("=", 1)
            meta[k] = v

PERIOD = float(meta["period"])
HOT    = float(meta["hot"])
NHOT   = int(meta["nhot"])
BASE   = meta.get("base_level", "?")
SHOCK  = meta.get("shock_load", "?")

# ── Lettura fronti ON (tempi relativi a T0 = start di hey) ─────────────────────
def load_on_edges(path):
    ons = []
    if not os.path.exists(path):
        return ons
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "ON":
                ons.append(float(parts[0]))
    return sorted(ons)

# ── Folding: per ogni richiesta calcola il "tempo dall'ultimo shock ON" e
#    aggrega i percentili per bin temporale (ensemble averaging su tutti i cicli).
def fold(algo):
    csv = os.path.join(results_dir, f"{algo}.csv")
    edges = load_on_edges(os.path.join(results_dir, f"{algo}_edges.log"))
    df = pd.read_csv(csv)

    # hey -o csv: colonne "response-time" e "offset" in secondi.
    rt  = df["response-time"].astype(float).values * 1000.0   # ms
    off = df["offset"].astype(float).values

    # fase = tempo trascorso dall'ultimo fronte ON, scartando ciò che precede il
    # primo shock e ciò che eccede un periodo (apparterrebbe al ciclo successivo).
    phase = np.full(len(off), np.nan)
    for i, o in enumerate(off):
        j = bisect.bisect_right(edges, o) - 1
        if j >= 0:
            d = o - edges[j]
            if d < PERIOD:
                phase[i] = d
    keep = ~np.isnan(phase)
    phase, rt = phase[keep], rt[keep]

    nb = int(np.ceil(PERIOD / BIN))
    centers, p50, p90, p99, cnt = [], [], [], [], []
    for b in range(nb):
        lo, hi = b * BIN, b * BIN + BIN
        sel = (phase >= lo) & (phase < hi)
        c = int(sel.sum())
        centers.append(lo + BIN / 2)
        cnt.append(c)
        if c < MIN_SAMPLES:
            p50.append(np.nan); p90.append(np.nan); p99.append(np.nan)
            continue
        v = rt[sel]
        p50.append(np.percentile(v, 50))
        p90.append(np.percentile(v, 90))
        p99.append(np.percentile(v, 99))
    return (np.array(centers), np.array(p50), np.array(p90),
            np.array(p99), np.array(cnt))

# ── Metriche del transitorio ──────────────────────────────────────────────────
def transient_metrics(centers, p99):
    """baseline (recuperato, fine COOL), picco durante ON, tempo di recupero."""
    pre = ~np.isnan(p99) & (centers < HOT)
    post = ~np.isnan(p99) & (centers >= HOT)
    # baseline = mediana dei bin di fine ciclo (ultimi 2s prima del prossimo ON)
    tail = ~np.isnan(p99) & (centers >= PERIOD - 2.0)
    baseline = np.nanmedian(p99[tail]) if tail.any() else np.nanmin(p99)
    peak = np.nanmax(p99[pre]) if pre.any() else np.nan
    # recupero: primo bin dopo OFF in cui p99 torna entro +20% del baseline
    recov = np.nan
    thr = baseline * 1.20
    for t, v in zip(centers[post], p99[post]):
        if not np.isnan(v) and v <= thr:
            recov = t - HOT
            break
    return baseline, peak, recov

pr_c, pr50, pr90, pr99, pr_n   = fold("prequal")
rr_c, rr50, rr90, rr99, rr_n   = fold("rr")

pr_base, pr_peak, pr_recov = transient_metrics(pr_c, pr99)
rr_base, rr_peak, rr_recov = transient_metrics(rr_c, rr99)

# ── Figura ─────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(9, 5.5))
fig.suptitle(
    "Risposta transitoria a uno shock correlato — Prequal vs Round Robin\n"
    f"(esperimento A: {NHOT}/10 backend a cpu_load={SHOCK}, carico base {BASE}× sat., "
    "ensemble averaging sui cicli)",
    fontsize=12, fontweight="bold", y=0.99)

# Regione "shock ON"
ax.axvspan(0, HOT, color="lightcoral", alpha=0.20, zorder=0)
ax.axvline(0,   color="gray", linestyle=":", lw=1.3, zorder=1)
ax.axvline(HOT, color="gray", linestyle=":", lw=1.3, zorder=1)
ax.text(HOT / 2, ax.get_ylim()[1] if False else 1, "SHOCK ON",
        ha="center", va="bottom", fontsize=8, color="#a33", transform=ax.get_xaxis_transform())
ax.text(HOT + 0.1, 0.97, "← shock OFF (recupero)", ha="left", va="top",
        fontsize=8, color="gray", transform=ax.get_xaxis_transform())

ax.set_yscale("log")

# p99 (linea spessa) + p50 (tratteggiata leggera) per entrambi gli algoritmi.
ax.plot(rr_c, rr99, color=COLOR_RR, lw=2.4, marker="^", markersize=5,
        label="RR  p99")
ax.plot(pr_c, pr99, color=COLOR_PREQUAL, lw=2.4, marker="^", markersize=5,
        label="Prequal p99")
ax.plot(rr_c, rr50, color=COLOR_RR, lw=1.3, linestyle="--", alpha=0.6,
        label="RR  p50")
ax.plot(pr_c, pr50, color=COLOR_PREQUAL, lw=1.3, linestyle="--", alpha=0.6,
        label="Prequal p50")

ax.set_xlabel("Tempo dallo shock (s)", fontsize=11)
ax.set_ylabel("Latenza (ms, log)", fontsize=11)
ax.set_xlim(0, PERIOD)
ax.grid(True, which="both", linestyle="--", alpha=0.35)
ax.legend(fontsize=9, loc="upper right", ncol=2, framealpha=0.9)

# Riquadro metriche
def fmt(x):
    return "—" if (x is None or (isinstance(x, float) and np.isnan(x))) else f"{x:.0f}"
txt = (
    "Picco p99 (durante ON):\n"
    f"   Prequal {fmt(pr_peak)} ms   |   RR {fmt(rr_peak)} ms\n"
    "Tempo di recupero (entro +20% baseline):\n"
    f"   Prequal {fmt(pr_recov)} s   |   RR {fmt(rr_recov)} s"
)
ax.text(0.015, 0.02, txt, transform=ax.transAxes, ha="left", va="bottom",
        fontsize=8.0, family="monospace",
        bbox=dict(boxstyle="round,pad=0.4", fc="white", ec="gray", alpha=0.9))

plt.tight_layout(rect=[0, 0, 1, 0.94])
out_path = os.path.join(results_dir, "shock_response.png")
plt.savefig(out_path, dpi=150, bbox_inches="tight")
print(f"Saved → {out_path}")

# ── Riepilogo a console (utile per il sweep di NHOT → regime 'no escape') ──────
print()
print(f"NHOT={NHOT}/10  base={BASE}x  shock_load={SHOCK}  periodo={PERIOD}s  HOT={HOT}s")
print(f"  baseline p99:  Prequal {fmt(pr_base)} ms | RR {fmt(rr_base)} ms")
print(f"  picco p99:     Prequal {fmt(pr_peak)} ms | RR {fmt(rr_peak)} ms"
      f"   (RR/Prequal = {rr_peak/pr_peak:.2f}x)" if pr_peak and not np.isnan(pr_peak) and pr_peak > 0 else "")
print(f"  recupero:      Prequal {fmt(pr_recov)} s  | RR {fmt(rr_recov)} s")
plt.close()
