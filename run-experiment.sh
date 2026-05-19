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
# Usage: ./run-experiment.sh [duration_per_step]   (default 60)

set -e

DURATION="${1:-60}"
LB_PREQUAL="http://10.10.1.11:8080"
LB_RR="http://10.10.1.12:8080"
RESULTS_DIR="/tmp/results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "============================================="
echo "Prequal vs Round-Robin - Load Ramp (fixed)"
echo "============================================="
echo "Duration per step:  ${DURATION}s"
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
LEVELS=(0.60 0.75 0.90 1.00 1.10 1.25 1.45 1.65 1.80)
NAMES=("60pct" "75pct" "90pct" "100pct" "110pct" "125pct" "145pct" "165pct" "180pct")

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

    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" "$LB_PREQUAL" \
        > "$RESULTS_DIR/prequal_${NAME}.txt" 2>&1 &
    PID_P=$!
    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" "$LB_RR" \
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
echo "============================================="
