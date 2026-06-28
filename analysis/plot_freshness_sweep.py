#!/usr/bin/env python3
"""
plot_freshness_sweep.py — Sweep di FRESCHEZZA del segnale (esperimento A, secondario).

Domanda: il vantaggio transitorio di Prequal dipende da QUANTO è fresco il segnale
di carico? Per misurarlo si esegue lo stesso shock (experiment-shock.sh) a più
probe interval e si confronta il rapporto RR/Prequal della p99 durante lo shock.

SETUP (use_server_rif=false, RIF client-local): il RIF — segnale dominante di HCL —
è tenuto in TEMPO REALE dall'LB, quindi resta sempre fresco a prescindere dal probe
interval. Variare il probe interval isola quindi l'effetto della staleness della SOLA
latenza (e della soglia RIF), tenendo fisso il segnale di carico. È il test giusto per
la ROBUSTEZZA: se il vantaggio transitorio di Prequal NON crolla allungando il probe
interval, significa che la policy non dipende da un probing frequente — si può ridurre
l'overhead di probing senza perdere il vantaggio.

Lo script annota nel titolo la sorgente RIF attiva così la figura è auto-documentante.

Usage:
  python3 plot_freshness_sweep.py DIR1 DIR2 DIR3 ...
  python3 plot_freshness_sweep.py "/tmp/results-shock-*_NHOT6_PI*"   # glob (tra apici)

Output: freshness_sweep.png nella cwd (o --out PATH).
"""

import sys
import os
import glob
import bisect
import re
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

BIN = 0.5
MIN_SAMPLES = 20
COLOR_PEAK = "#d62728"
COLOR_MEAN = "#1f77b4"


def read_meta(d):
    meta = {}
    with open(os.path.join(d, "meta.env")) as f:
        for line in f:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k] = v
    return meta


def load_on_edges(path):
    ons = []
    if os.path.exists(path):
        for line in open(path):
            p = line.split()
            if len(p) >= 2 and p[1] == "ON":
                ons.append(float(p[0]))
    return sorted(ons)


def measure_on_duration(path):
    if not os.path.exists(path):
        return None
    evs = [ln.split() for ln in open(path) if len(ln.split()) >= 2]
    ts = [float(t) for t, _ in evs]
    ev = [e for _, e in evs]
    durs = [ts[i + 1] - ts[i] for i in range(len(ev) - 1)
            if ev[i] == "ON" and ev[i + 1] == "OFF"]
    return float(np.median(durs)) if durs else None


def fold_p99(d, algo, period):
    """p99(t) folded/ensemble-averaged in BIN-second bins (centers, p99)."""
    df = pd.read_csv(os.path.join(d, f"{algo}.csv"))
    edges = load_on_edges(os.path.join(d, f"{algo}_edges.log"))
    rt = df["response-time"].astype(float).values * 1000.0
    off = df["offset"].astype(float).values
    phase = np.full(len(off), np.nan)
    for i, o in enumerate(off):
        j = bisect.bisect_right(edges, o) - 1
        if j >= 0 and (o - edges[j]) < period:
            phase[i] = o - edges[j]
    keep = ~np.isnan(phase)
    phase, rt = phase[keep], rt[keep]
    nb = int(np.ceil(period / BIN))
    centers, p99 = [], []
    for b in range(nb):
        lo, hi = b * BIN, b * BIN + BIN
        sel = (phase >= lo) & (phase < hi)
        centers.append(lo + BIN / 2)
        p99.append(np.percentile(rt[sel], 99) if sel.sum() >= MIN_SAMPLES else np.nan)
    return np.array(centers), np.array(p99)


def peak_mean_during_shock(d):
    """RR/Prequal ratio of p99 PEAK and p99 MEAN over the shock-ON window."""
    meta = read_meta(d)
    period = float(meta["period"])
    hot_cfg = float(meta["hot"])
    ons = [measure_on_duration(os.path.join(d, f"{a}_edges.log")) for a in ("prequal", "rr")]
    ons = [x for x in ons if x]
    hot = float(np.mean(ons)) if ons else hot_cfg
    pr_c, pr99 = fold_p99(d, "prequal", period)
    rr_c, rr99 = fold_p99(d, "rr", period)
    on = ~np.isnan(pr99) & (pr_c < hot)
    onr = ~np.isnan(rr99) & (rr_c < hot)
    pr_peak, pr_mean = np.nanmax(pr99[on]), np.nanmean(pr99[on])
    rr_peak, rr_mean = np.nanmax(rr99[onr]), np.nanmean(rr99[onr])
    return rr_peak / pr_peak, rr_mean / pr_mean, meta


def iv_to_seconds(iv):
    m = re.match(r"([\d.]+)\s*(ms|s)?", iv)
    if not m:
        return float("inf")
    val = float(m.group(1))
    return val / 1000.0 if m.group(2) == "ms" else val


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = "freshness_sweep.png"
    for a in sys.argv[1:]:
        if a.startswith("--out="):
            out = a.split("=", 1)[1]
    # expand any glob patterns
    dirs = []
    for a in args:
        g = glob.glob(a)
        dirs.extend(g if g else [a])
    dirs = [d for d in dirs if os.path.isdir(d) and os.path.exists(os.path.join(d, "meta.env"))]
    if len(dirs) < 2:
        print("ERRORE: servono >=2 cartelle di risultato (un probe interval ciascuna).")
        print("Esempio: python3 plot_freshness_sweep.py results/results-shock-*_PI*")
        sys.exit(1)

    rows = []
    rif_srcs = set()
    for d in dirs:
        peak_r, mean_r, meta = peak_mean_during_shock(d)
        iv = meta.get("probe_interval", "?")
        usr = meta.get("use_server_rif", "unknown")
        rif_srcs.add(usr)
        rows.append((iv_to_seconds(iv), iv, peak_r, mean_r, usr, meta))
        print(f"{os.path.basename(d)}  PI={iv}  use_server_rif={usr}  "
              f"peak RR/Prequal={peak_r:.2f}x  mean RR/Prequal={mean_r:.2f}x")

    rows.sort(key=lambda r: r[0])
    x = list(range(len(rows)))
    labels = [r[1] for r in rows]
    peaks = [r[2] for r in rows]
    means = [r[3] for r in rows]
    meta0 = rows[0][5]
    nhot = meta0.get("nhot", "?")
    base = meta0.get("base_level", "?")

    fig, ax = plt.subplots(figsize=(9, 5.5))
    if rif_srcs == {"false"}:
        rif_tag = "use_server_rif=false (client-local, real-time RIF)"
    elif rif_srcs == {"true"}:
        rif_tag = "use_server_rif=true (probe-delivered RIF)"
    else:
        rif_tag = "use_server_rif mixed: " + ",".join(sorted(rif_srcs))
    fig.suptitle(
        "Signal-freshness sweep — Prequal's transient advantage vs probe interval\n"
        f"({nhot}/10 backends, base load {base}x sat., {rif_tag})",
        fontsize=12, fontweight="bold")

    ax.plot(x, peaks, color=COLOR_PEAK, marker="o", lw=2.4, label="peak p99  RR/Prequal")
    ax.plot(x, means, color=COLOR_MEAN, marker="s", ls="--", lw=2.0, label="mean p99  RR/Prequal")
    for xi, p, m in zip(x, peaks, means):
        ax.annotate(f"{p:.2f}x", (xi, p), textcoords="offset points", xytext=(0, 8),
                    ha="center", color=COLOR_PEAK, fontsize=9)
        ax.annotate(f"{m:.2f}x", (xi, m), textcoords="offset points", xytext=(0, -14),
                    ha="center", color=COLOR_MEAN, fontsize=9)
    ax.axhline(1.0, color="gray", ls=":", lw=1.2)
    ax.text(x[-1], 1.005, "no advantage (RR = Prequal)", ha="right", va="bottom",
            color="gray", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_xlabel("Probe interval (signal freshness →  staler)", fontsize=11)
    ax.set_ylabel("Prequal advantage  (p99 RR / p99 Prequal)", fontsize=11)
    ax.grid(True, ls="--", alpha=0.35)
    ax.legend(fontsize=10, loc="best")
    plt.tight_layout(rect=[0, 0, 1, 0.93])
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"\nSaved → {out}")
    if rif_srcs == {"false"}:
        print("Nota: RIF client-local (real-time). Lo sweep isola la staleness della sola")
        print("      latenza; il vantaggio che resta ~costante = robustezza al probe rate.")


if __name__ == "__main__":
    main()
