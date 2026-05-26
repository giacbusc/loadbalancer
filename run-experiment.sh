#!/bin/bash
# run-experiment.sh - Load-ramp experiment, FIXED VERSION.
#
# Key fixes vs. the broken version:
#   1. Real saturation discovery: an uncapped hey burst finds the TRUE
#      max throughput, instead of trusting a "-q 200" that hey ignores.
#   2. Absolute QPS levels around and BEYOND that saturation point, so the
#      system actually enters the overload regime where Prequal vs RR diverge.
#   3. Antagonists must be strong (set in profile.py: cpu_load 350/150/0).
#
# Usage: ./run-experiment.sh [duration_per_step] [dynamic]   (default: 60, static)
#
# Esempi:
#   ./run-experiment.sh          # 60s per step, antagonisti statici
#   ./run-experiment.sh 60       # idem esplicito
#   ./run-experiment.sh 60 dynamic   # antagonisti dinamici (cambiano ogni 10s)
#
# Con "dynamic" viene avviato dynamic-antagonist.sh in background;
# ad ogni step dell'esperimento i server cambiano carico ciclicamente,
# rendendo più evidente la differenza tra Prequal e Round-Robin.

set -e

DURATION="${1:-60}"
DYNAMIC="${2:-}"          # se "dynamic", avvia il ciclo antagonista
ANTAG_PID=""              # PID del processo antagonista (se avviato)
LB_PREQUAL="http://10.10.1.11:8080"
LB_RR="http://10.10.1.12:8080"
RESULTS_DIR="/tmp/results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "============================================="
echo "Prequal vs Round-Robin - Load Ramp (fixed)"
echo "============================================="
echo "Duration per step:  ${DURATION}s"
echo "Antagonist mode:    ${DYNAMIC:-static}"
echo "Results directory:  $RESULTS_DIR"
echo

for url in "$LB_PREQUAL/health" "$LB_RR/health"; do
    if ! curl -fsS "$url" > /dev/null; then
        echo "ERROR: $url not reachable" >&2
        exit 1
    fi
done
echo "Both LBs reachable."
echo

# ---------------------------------------------------------------------------
# ANTAGONISTA DINAMICO (opzionale)
# Avvia dynamic-antagonist.sh in background se richiesto.
# Lo script cambia il carico dei backend ogni 10s chiamando /admin/load.
# ---------------------------------------------------------------------------
if [ "$DYNAMIC" = "dynamic" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ANTAG_SCRIPT="$SCRIPT_DIR/dynamic-antagonist.sh"
    if [ ! -x "$ANTAG_SCRIPT" ]; then
        echo "ERROR: $ANTAG_SCRIPT non trovato o non eseguibile." >&2
        echo "  Esegui: chmod +x dynamic-antagonist.sh" >&2
        exit 1
    fi
    echo "--- Avvio dynamic-antagonist.sh in background ---"
    ANTAG_LOG="/tmp/antagonist-$(date +%Y%m%d-%H%M%S).log"
    ANTAG_LOG="$ANTAG_LOG" "$ANTAG_SCRIPT" &
    ANTAG_PID=$!
    echo "  PID antagonista: $ANTAG_PID"
    echo "  Log antagonista: $ANTAG_LOG"
    sleep 3   # lascia tempo all'antagonista di applicare il primo stato
    echo "  Antagonista attivo."
    echo
fi

# Registra cleanup: ferma l'antagonista e ripristina il carico base
cleanup() {
    if [ -n "$ANTAG_PID" ] && kill -0 "$ANTAG_PID" 2>/dev/null; then
        echo ""
        echo "--- Arresto dynamic-antagonist (PID $ANTAG_PID) ---"
        kill "$ANTAG_PID" 2>/dev/null || true
        wait "$ANTAG_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# STEP 1: Discover the TRUE saturation throughput.
# We send an UNCAPPED burst (no -q) with high concurrency. hey will push as
# hard as it can; Requests/sec is then the real ceiling under this workload
# and the current antagonist configuration.
# ---------------------------------------------------------------------------
echo "--- Saturation discovery (20s, uncapped, c=200, both LBs) ---"
hey -z 20s -c 200 "$LB_PREQUAL" > "$RESULTS_DIR/saturation_prequal.txt" 2>&1 &
hey -z 20s -c 200 "$LB_RR"     > "$RESULTS_DIR/saturation_rr.txt"     2>&1 &
wait
SAT=$(grep -E "^[[:space:]]*Requests/sec:" "$RESULTS_DIR/saturation_prequal.txt" | awk '{print $2}' | head -1)
SAT_INT=${SAT%.*}
echo "Measured saturation throughput (per LB, both running): ${SAT_INT} req/s"
echo

if [ -z "$SAT_INT" ] || [ "$SAT_INT" -lt 100 ]; then
    echo "ERROR: saturation discovery failed (got '$SAT_INT'). Check hey and LBs." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# STEP 2: Ramp the load from clearly-under-capacity to clearly-over-capacity.
# We go from 0.6x of saturation up to 1.8x. Above 1.0x the system is
# overloaded; this is the zone where RR collapses and Prequal holds.
# We CAP hey with -q so the requested rate is enforced. We also raise
# concurrency so the cap is actually reachable.
# ---------------------------------------------------------------------------
LEVELS=(0.75 0.83 0.93 1.03 1.14 1.27 1.41 1.57 1.74)
NAMES=("75pct" "83pct" "93pct" "103pct" "114pct" "127pct" "141pct" "157pct" "174pct")

for i in "${!LEVELS[@]}"; do
    LEVEL=${LEVELS[$i]}
    NAME=${NAMES[$i]}
    QPS=$(awk -v s="$SAT_INT" -v l="$LEVEL" 'BEGIN{printf "%.0f", s*l}')

    echo "==================================="
    echo "Step $((i+1))/9 - $NAME (target ${QPS} req/s)"
    echo "==================================="

    # Concurrency high enough to actually drive QPS even when the system
    # is slow under overload (otherwise hey self-throttles).
    # NOTE: hey's -q is per-worker, so divide total target QPS by concurrency.
    CONC=300
    QPS_PER_WORKER=$(awk -v q="$QPS" -v c="$CONC" 'BEGIN{printf "%.0f", q/c}')
    [ "$QPS_PER_WORKER" -lt 1 ] && QPS_PER_WORKER=1

    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" -t 5 "$LB_PREQUAL" \
        > "$RESULTS_DIR/prequal_${NAME}.txt" 2>&1 &
    PID_P=$!
    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" -t 5 "$LB_RR" \
        > "$RESULTS_DIR/rr_${NAME}.txt" 2>&1 &
    PID_R=$!

    wait "$PID_P" "$PID_R"

    echo "  Prequal:"
    grep -E "Requests/sec|99%|95%|50%" "$RESULTS_DIR/prequal_${NAME}.txt" | head -4 | sed 's/^/    /'
    echo "  RR:"
    grep -E "Requests/sec|99%|95%|50%" "$RESULTS_DIR/rr_${NAME}.txt" | head -4 | sed 's/^/    /'
    echo

    sleep 5
done

echo "============================================="
echo "Experiment complete. Results in: $RESULTS_DIR"
echo "Parse with: ./parse-results.sh $RESULTS_DIR"
if [ -n "$ANTAG_PID" ]; then
    echo "Antagonist log:    $ANTAG_LOG"
fi
echo "============================================="
