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

PERIOD   = float(meta["period"])
HOT_CFG  = float(meta["hot"])      # valore CONFIGURATO (può differire dal reale)
NHOT     = int(meta["nhot"])
BASE     = meta.get("base_level", "?")
SHOCK    = meta.get("shock_load", "?")

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

# Durata ON REALE misurata dai log (le curl di /admin/load + wait aggiungono
# overhead allo sleep HOT, così lo shock dura più di HOT_CFG). Usiamo la mediana
# OFF−ON sui cicli di entrambe le passate, così la figura e lo split ON/OFF
# rispecchiano lo shock effettivamente applicato.
def measure_on_duration(path):
    if not os.path.exists(path):
        return None
    evs = [ln.split() for ln in open(path) if len(ln.split()) >= 2]
    ts = [float(t) for t, _ in evs]
    ev = [e for _, e in evs]
    durs = [ts[i + 1] - ts[i] for i in range(len(ev) - 1)
            if ev[i] == "ON" and ev[i + 1] == "OFF"]
    return float(np.median(durs)) if durs else None

_ons = [measure_on_duration(os.path.join(results_dir, f"{a}_edges.log"))
        for a in ("prequal", "rr")]
_ons = [x for x in _ons if x]
HOT = float(np.mean(_ons)) if _ons else HOT_CFG   # durata ON effettiva per fold/figura

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
def baseline_of(centers, p99):
    """Livello recuperato: mediana p99 nei bin di fine ciclo (ultimi 2s di COOL)."""
    tail = ~np.isnan(p99) & (centers >= PERIOD - 2.0)
    return np.nanmedian(p99[tail]) if tail.any() else np.nanmin(p99)

def metrics(centers, p99, common_thr):
    """picco durante ON, p99 medio durante ON, recupero verso una soglia COMUNE.

    Il recupero usa una soglia ASSOLUTA condivisa tra le due policy: altrimenti,
    misurandolo rispetto al proprio baseline, la policy con baseline più alto
    sembrerebbe 'recuperare prima' pur avendo p99 assoluta maggiore (fuorviante).
    """
    pre  = ~np.isnan(p99) & (centers < HOT)
    post = ~np.isnan(p99) & (centers >= HOT)
    peak      = np.nanmax(p99[pre])  if pre.any()  else np.nan
    mean_on   = np.nanmean(p99[pre]) if pre.any()  else np.nan
    recov = np.nan
    for t, v in zip(centers[post], p99[post]):
        if not np.isnan(v) and v <= common_thr:
            recov = t - HOT
            break
    return peak, mean_on, recov

pr_c, pr50, pr90, pr99, pr_n   = fold("prequal")
rr_c, rr50, rr90, rr99, rr_n   = fold("rr")

pr_base = baseline_of(pr_c, pr99)
rr_base = baseline_of(rr_c, rr99)
# soglia di recupero COMUNE: +20% del baseline peggiore (confronto equo).
COMMON_THR = max(pr_base, rr_base) * 1.20

pr_peak, pr_mean, pr_recov = metrics(pr_c, pr99, COMMON_THR)
rr_peak, rr_mean, rr_recov = metrics(rr_c, rr99, COMMON_THR)

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
peak_ratio = rr_peak / pr_peak if (pr_peak and not np.isnan(pr_peak) and pr_peak > 0) else float("nan")
mean_ratio = rr_mean / pr_mean if (pr_mean and not np.isnan(pr_mean) and pr_mean > 0) else float("nan")
txt = (
    "p99 durante shock (RR vs Prequal):\n"
    f"   picco  {fmt(rr_peak)} / {fmt(pr_peak)} ms  = {peak_ratio:.2f}x\n"
    f"   media  {fmt(rr_mean)} / {fmt(pr_mean)} ms  = {mean_ratio:.2f}x\n"
    f"Recupero (entro +20% di {fmt(COMMON_THR/1.2)} ms, soglia comune):\n"
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
print(f"NHOT={NHOT}/10  base={BASE}x  shock_load={SHOCK}  periodo={PERIOD}s  HOT_reale={HOT:.1f}s (cfg {HOT_CFG:.0f}s)")
print(f"  baseline p99:        Prequal {fmt(pr_base)} ms | RR {fmt(rr_base)} ms")
print(f"  picco p99 (ON):      Prequal {fmt(pr_peak)} ms | RR {fmt(rr_peak)} ms  (RR/Prequal = {peak_ratio:.2f}x)")
print(f"  media p99 (ON):      Prequal {fmt(pr_mean)} ms | RR {fmt(rr_mean)} ms  (RR/Prequal = {mean_ratio:.2f}x)")
print(f"  recupero (soglia comune {fmt(COMMON_THR/1.2)} ms +20%):  Prequal {fmt(pr_recov)} s | RR {fmt(rr_recov)} s")
plt.close()
