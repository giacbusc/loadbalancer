#!/bin/bash
# experiment-shock.sh — TRANSIENT RESPONSE to a correlated shock (experiment A).
#
# MOTIVATION (further exploration, goes BEYOND the paper):
#   All the paper's experiments (and ours so far) measure the system at
#   STEADY STATE: one equilibrium point per load level, tail-latency vs
#   load. The paper NEVER looks at the TIME DOMAIN:
#     1. how quickly each policy REACTS to a sudden shock, and
#     2. how long it takes to RECOVER after the shock ends.
#   Moreover, the paper always assumes the existence of a "cold majority" that
#   Prequal can divert to. Here we hit NHOT out of 10 backends SIMULTANEOUSLY
#   (a CORRELATED shock, not our independent antagonists) and, by varying NHOT,
#   we find the point where that cold majority disappears and Prequal's
#   advantage vanishes (the "no escape" regime).
#
# HOW (without changing anything major):
#   - CONSTANT load (BASE_LEVEL × saturation) for the whole pass, as in
#     experiment-ab.sh, with saturation discovery done once on RR.
#   - Antagonist square wave: WARMUP, then ON (NHOT backends at SHOCK_LOAD) for
#     HOT seconds, OFF (all clean) for COOL seconds, repeated NCYCLES times.
#     Each cycle is a repeated shock event → ensemble averaging in the plot.
#   - hey is launched with "-o csv": it reports EVERY request with
#     (response-time, offset) so plot_shock.py can bin at 0.5s and reconstruct
#     p99(t). hey's 60s aggregate alone would smear out the transient and make
#     it invisible.
#   - A/B in two identical passes (all-Prequal, all-RR) as in experiment-ab.sh,
#     via /admin/algorithm at runtime: same shock schedule, only the algo changes.
#
# Usage: ./experiment-shock.sh [duration_per_pass] [nhot]
#   ./experiment-shock.sh                 # 108s/pass (8 cycles), 6 backends hit
#   ./experiment-shock.sh 108 4           # 108s/pass, 4 backends hit
#   NHOT sweep ("no escape" regime):
#   for n in 2 4 6 8; do ./experiment-shock.sh 108 $n; done
#   Long shock (old default): HOT=8 COOL=12 ./experiment-shock.sh 180 6
#
# Environment variables (optional overrides):
#   BASE_LEVEL  constant load as a fraction of saturation          (default 1.00)
#   HOT         seconds of shock ON (short shock to isolate the lag)   (default 3)
#   COOL        seconds of recovery OFF                             (default 9)
#   WARMUP      seconds before the first shock                      (default 12)
#   SHOCK_LOAD  cpu_load applied to the backends being hit          (default 350)
#   CONC        connections per LB                                  (default 1000)

set -uo pipefail

DURATION="${1:-108}"
NHOT="${2:-6}"
BASE_LEVEL="${BASE_LEVEL:-1.00}"
HOT="${HOT:-3}"
COOL="${COOL:-9}"
WARMUP="${WARMUP:-12}"
SHOCK_LOAD="${SHOCK_LOAD:-350}"
CONC="${CONC:-1000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LB1="http://10.10.1.11:8080"
LB2="http://10.10.1.12:8080"
LBS=("$LB1" "$LB2")

# Backends server-0..9 → 10.10.1.21..30 (same as experiment-ab.sh)
BACKENDS=(10.10.1.21 10.10.1.22 10.10.1.23 10.10.1.24 10.10.1.25
          10.10.1.26 10.10.1.27 10.10.1.28 10.10.1.29 10.10.1.30)

PERIOD=$(( HOT + COOL ))
NCYCLES=$(awk -v d="$DURATION" -v w="$WARMUP" -v p="$PERIOD" 'BEGIN{printf "%d", (d-w)/p}')

RESULTS_DIR="/tmp/results-shock-$(date +%Y%m%d-%H%M%S)_NHOT${NHOT}"
mkdir -p "$RESULTS_DIR/_lb2"

T0=""   # set per-pass right before launching hey

echo "============================================="
echo " Shock transitorio — Prequal vs RR (esperimento A)"
echo "============================================="
echo " Duration/passata: ${DURATION}s"
echo " Backend colpiti:  ${NHOT}/10  (cpu_load=${SHOCK_LOAD})"
echo " Onda quadra:      WARMUP=${WARMUP}s | HOT=${HOT}s | COOL=${COOL}s | periodo=${PERIOD}s | cicli=${NCYCLES}"
echo " Carico base:      ${BASE_LEVEL}× saturazione (costante)"
echo " Results dir:      $RESULTS_DIR"
echo

if [ "$NCYCLES" -lt 3 ]; then
    echo "ATTENZIONE: solo ${NCYCLES} cicli di shock — ensemble averaging debole." >&2
    echo "            Aumenta la durata (es. ./experiment-shock.sh 240 ${NHOT})." >&2
fi

# --- Reachability -----------------------------------------------------------
for lb in "${LBS[@]}"; do
    if ! curl -fsS "$lb/health" >/dev/null; then
        echo "ERROR: $lb non raggiungibile" >&2
        exit 1
    fi
done
echo "Entrambi gli LB raggiungibili."

# ACTIVE probe interval read from the LB (GET /admin/probe-interval), so the
# directory and meta.env are self-documenting for the freshness sweep.
# If the LB is an old build without the endpoint, fall back to "unknown".
PROBE_IV=$(curl -fsS "$LB1/admin/probe-interval" 2>/dev/null | tr -d '[:space:]')
[ -z "$PROBE_IV" ] && PROBE_IV="unknown"
# Active RIF source: true = server-local (probed, can go stale), false = client-local (real-time).
RIF_SRC=$(curl -fsS "$LB1/admin/use-server-rif" 2>/dev/null | tr -d '[:space:]')
[ -z "$RIF_SRC" ] && RIF_SRC="unknown"
RIF_TAG="srv"; [ "$RIF_SRC" = "false" ] && RIF_TAG="loc"
NEW_DIR="${RESULTS_DIR}_PI${PROBE_IV}_RIF${RIF_TAG}"
mv "$RESULTS_DIR" "$NEW_DIR" && RESULTS_DIR="$NEW_DIR"
echo "Probe interval attivo: ${PROBE_IV} | use_server_rif: ${RIF_SRC}"
echo "Results dir: $RESULTS_DIR"
echo

# ---------------------------------------------------------------------------
# Helpers (same as experiment-ab.sh)
# ---------------------------------------------------------------------------
set_algo() {
    local algo="$1"
    for lb in "${LBS[@]}"; do
        if ! curl -fsS "${lb}/admin/algorithm?algo=${algo}" >/dev/null; then
            echo "ERROR: impossibile impostare algo=$algo su $lb" >&2
            exit 1
        fi
    done
    echo "  → algoritmo impostato a '$algo' su tutti gli LB"
}

req_per_sec() {
    grep -E "^[[:space:]]*Requests/sec:" "$1" 2>/dev/null | awk '{print $2}' | head -1
}

# Bring ALL backends to cpu_load=0 (in parallel).
reset_clean() {
    local pids=()
    for ip in "${BACKENDS[@]}"; do
        curl -fsS --max-time 2 "http://${ip}:8080/admin/load?cpu=0" >/dev/null 2>&1 &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
}

# Apply a cpu_load value to the FIRST NHOT backends (in parallel).
shock_set() {
    local val="$1"; local pids=()
    local i
    for ((i=0; i<NHOT; i++)); do
        curl -fsS --max-time 2 "http://${BACKENDS[$i]}:8080/admin/load?cpu=${val}" \
            >/dev/null 2>&1 &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
}

# Log an edge (ON/OFF) with the time elapsed since T0 (= hey's start instant).
log_edge() {
    local ev="$1"; local edgelog="$2"; local now
    now=$(date +%s.%N)
    awk -v a="$now" -v b="$T0" -v e="$ev" 'BEGIN{printf "%.3f %s\n", a-b, e}' >> "$edgelog"
}

cleanup() {
    reset_clean
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Saturation discovery — ONCE ONLY, on RR (common reference).
# ---------------------------------------------------------------------------
echo "--- Saturation discovery (20s, uncapped, c=200, riferimento=RR) ---"
set_algo rr
reset_clean
sleep 5
hey -z 20s -c 200 "$LB1" > "$RESULTS_DIR/saturation_ref.txt"      2>&1 &
P1=$!
hey -z 20s -c 200 "$LB2" > "$RESULTS_DIR/_lb2/saturation_ref.txt" 2>&1 &
P2=$!
wait "$P1" "$P2"

SAT=$(req_per_sec "$RESULTS_DIR/saturation_ref.txt")
SAT_INT=${SAT%.*}
echo "Saturazione di riferimento (per-LB): ${SAT_INT} req/s"
if [ -z "$SAT_INT" ] || [ "$SAT_INT" -lt 100 ]; then
    echo "ERROR: saturation discovery fallita (got '$SAT_INT')." >&2
    exit 1
fi

QPS=$(awk -v s="$SAT_INT" -v l="$BASE_LEVEL" 'BEGIN{printf "%.0f", s*l}')
QPS_PER_WORKER=$(awk -v q="$QPS" -v c="$CONC" 'BEGIN{printf "%.4f", q/c}')
echo "Carico base costante: ${QPS} req/s per LB (${BASE_LEVEL}× saturazione)"
echo

# Metadata for the plotter (read as key=value).
cat > "$RESULTS_DIR/meta.env" <<EOF
period=$PERIOD
hot=$HOT
cool=$COOL
warmup=$WARMUP
nhot=$NHOT
base_level=$BASE_LEVEL
sat=$SAT_INT
qps=$QPS
shock_load=$SHOCK_LOAD
ncycles=$NCYCLES
probe_interval=$PROBE_IV
use_server_rif=$RIF_SRC
EOF

# ---------------------------------------------------------------------------
# One pass: sets the algorithm, launches hey at constant load with -o csv,
# and in parallel drives the shock square wave, logging the edges.
# ---------------------------------------------------------------------------
run_pass() {
    local ALGO="$1"
    echo "#############################################"
    echo "#  PASSATA: ${ALGO}  (entrambi gli LB)"
    echo "#############################################"
    set_algo "$ALGO"
    sleep 5            # warm-up after the switch: the RIF threshold is recomputed on the next probe
    reset_clean
    sleep 2

    local edgelog="$RESULTS_DIR/${ALGO}_edges.log"
    : > "$edgelog"

    # T0 = hey's start instant; the offsets in hey -o csv are relative to this.
    T0=$(date +%s.%N)

    # Canonical LB (.11) → per-request CSV (parsed by plot_shock.py).
    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" -o csv "$LB1" \
        > "$RESULTS_DIR/${ALGO}.csv" 2>"$RESULTS_DIR/${ALGO}.err" &
    local HPID=$!
    # Co-load LB (.12) → second half of the fleet load (output ignored).
    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" "$LB2" \
        > "$RESULTS_DIR/_lb2/${ALGO}.txt" 2>&1 &
    local HPID2=$!

    # Shock square wave, synchronized with hey via T0.
    (
        sleep "$WARMUP"
        local k
        for ((k=0; k<NCYCLES; k++)); do
            shock_set "$SHOCK_LOAD"; log_edge ON  "$edgelog"; sleep "$HOT"
            shock_set 0;            log_edge OFF "$edgelog"; sleep "$COOL"
        done
    ) &
    local SPID=$!

    wait "$HPID" "$HPID2"
    kill "$SPID" 2>/dev/null || true
    wait "$SPID" 2>/dev/null || true
    reset_clean

    local nreq
    nreq=$(($(wc -l < "$RESULTS_DIR/${ALGO}.csv") - 1))
    echo "  → ${ALGO}: ${nreq} richieste registrate, $(grep -c ' ON' "$edgelog") shock"
    echo
}

# ---------------------------------------------------------------------------
# The two passes
# ---------------------------------------------------------------------------
run_pass prequal

echo "--- cooldown 10s tra le due passate ---"
sleep 10

run_pass rr

# ---------------------------------------------------------------------------
# Plot
# ---------------------------------------------------------------------------
echo "============================================="
echo "Esperimento shock completo. Risultati in: $RESULTS_DIR"
PLOT_SHOCK="$SCRIPT_DIR/../analysis/plot_shock.py"
if command -v python3 >/dev/null && [ -f "$PLOT_SHOCK" ]; then
    echo "--- plot_shock.py ---"
    python3 "$PLOT_SHOCK" "$RESULTS_DIR" || true
else
    echo "Plotta con: python3 analysis/plot_shock.py $RESULTS_DIR"
fi
echo "============================================="