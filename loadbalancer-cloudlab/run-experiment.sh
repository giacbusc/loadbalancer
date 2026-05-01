#!/bin/bash
# run-experiment.sh — main load-ramp experiment, replicating Figure 6 of the
# Prequal paper. Runs from a loadgen node and targets both LBs in parallel.
#
# Usage: ./run-experiment.sh [duration_per_step]
#   default duration: 60 seconds per step

set -e

DURATION="${1:-60}"
LB_PREQUAL="http://10.10.1.11:8080"
LB_RR="http://10.10.1.12:8080"
RESULTS_DIR="/tmp/results-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$RESULTS_DIR"

echo "============================================="
echo "Prequal vs Round-Robin — Load Ramp Experiment"
echo "============================================="
echo "Duration per step:  ${DURATION}s"
echo "Results directory:  $RESULTS_DIR"
echo

# Sanity check: both LBs reachable.
for url in "$LB_PREQUAL/health" "$LB_RR/health"; do
    if ! curl -fsS "$url" > /dev/null; then
        echo "ERROR: $url not reachable" >&2
        exit 1
    fi
done
echo "Both LBs are reachable."
echo

# 1. Calibration: find a baseline QPS where Prequal stays comfortably under load.
echo "--- Calibration (15s @ Prequal) ---"
hey -z 15s -q 100 -c 50 "$LB_PREQUAL" > "$RESULTS_DIR/calibration.txt" 2>&1
BASELINE=$(grep "Requests/sec:" "$RESULTS_DIR/calibration.txt" | awk '{print $2}' | head -1)
BASELINE_INT=${BASELINE%.*}
echo "Baseline throughput: ${BASELINE_INT} req/s"
echo

# 2. Run the load ramp (75% → 174% of baseline).
LEVELS=(0.75 0.83 0.93 1.03 1.14 1.27 1.41 1.57 1.74)
NAMES=("75pct" "83pct" "93pct" "103pct" "114pct" "127pct" "141pct" "157pct" "174pct")

for i in "${!LEVELS[@]}"; do
    LEVEL=${LEVELS[$i]}
    NAME=${NAMES[$i]}
    QPS=$(echo "$BASELINE_INT * $LEVEL" | bc | awk '{printf "%.0f", $1}')

    echo "==================================="
    echo "Step $((i+1))/9 — $NAME (~${QPS} req/s)"
    echo "==================================="

    # Launch both load tests in parallel.
    hey -z "${DURATION}s" -q "$QPS" -c 50 "$LB_PREQUAL" \
        > "$RESULTS_DIR/prequal_${NAME}.txt" 2>&1 &
    PID_P=$!
    hey -z "${DURATION}s" -q "$QPS" -c 50 "$LB_RR" \
        > "$RESULTS_DIR/rr_${NAME}.txt" 2>&1 &
    PID_R=$!

    wait "$PID_P" "$PID_R"

    echo "  Prequal:"
    grep -E "Requests/sec|Average|Slowest|99%|95%|50%" "$RESULTS_DIR/prequal_${NAME}.txt" | head -6 | sed 's/^/    /'
    echo "  RR:"
    grep -E "Requests/sec|Average|Slowest|99%|95%|50%" "$RESULTS_DIR/rr_${NAME}.txt" | head -6 | sed 's/^/    /'
    echo

    sleep 5
done

echo "============================================="
echo "Experiment complete!"
echo "Results in: $RESULTS_DIR"
echo "============================================="
echo
echo "To extract a CSV summary:"
echo "  ./parse-results.sh $RESULTS_DIR"
