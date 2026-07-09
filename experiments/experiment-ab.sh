#!/bin/bash
# experiment-ab.sh — CLEAN A/B in two passes, with no contamination.
#
# IDEA (see discussion):
#   Instead of keeping lb-prequal and lb-rr running SIMULTANEOUSLY on the same
#   backends (the two algorithms step on each other: Prequal routes to the idle
#   server while RR floods it → Prequal's signal gets erased), we run TWO
#   separate passes, setting BOTH LBs to the same algorithm via endpoint:
#
#     Pass 1:  .11 = prequal,  .12 = prequal   (all-Prequal fleet)
#     Pass 2:  .11 = rr,       .12 = rr        (all-RR fleet)
#
#   Within a pass the routing is HOMOGENEOUS → no contamination.
#   Pass 1 is then compared against Pass 2. It's a true A/B: same backends,
#   same antagonist, same load; only the algorithm changes.
#
# The algorithm is switched at runtime with /admin/algorithm?algo=prequal|rr
# (cmd/server/main.go:117) → no redeploy between the two passes.
#
# -----------------------------------------------------------------------------
# IMPORTANT PREREQUISITE (for a comparison that is fair to Prequal):
#   The LBs should run with  LB_USE_SERVER_RIF=true  (env at boot,
#   cloudlab-setup.sh:99). With two Prequal LBs in parallel and
#   USE_SERVER_RIF=false, each LB only counts its OWN in-flight per server and
#   cannot see the other LB → they can both pick the same "idle" server and
#   overload it together (multi-LB herd effect). With true, each LB reads the
#   TOTAL RIF reported by the backend (X-Server-RIF) and the signal is
#   complete. RR is unaffected.
#   This script CANNOT change it at runtime (it's an env var): verify it first.
# -----------------------------------------------------------------------------
#
# Usage: ./experiment-ab.sh [duration_per_step] [static|dynamic]
#   ./experiment-ab.sh              # 60s/step, heterogeneous STATIC antagonist
#   ./experiment-ab.sh 60 dynamic   # 60s/step, cyclic DYNAMIC antagonist

set -uo pipefail

DURATION="${1:-60}"
MODE="${2:-static}"               # static | dynamic
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LB1="http://10.10.1.11:8080"
LB2="http://10.10.1.12:8080"
LBS=("$LB1" "$LB2")

# Backends server-0..9 → 10.10.1.21..30
BACKENDS=(10.10.1.21 10.10.1.22 10.10.1.23 10.10.1.24 10.10.1.25
          10.10.1.26 10.10.1.27 10.10.1.28 10.10.1.29 10.10.1.30)

# Minority-load STATIC profile: only 3 heavy servers (350), 7 clean (0),
# so Prequal always has plenty of capacity to divert to. (cpu_load s0..s9)
# This is the paper's scenario: a few antagonists among many healthy replicas.
STATIC_LOADS=(350 350 350 0 0 0 0 0 0 0)

CONC=1000                          # connections per LB
LEVELS=(0.75 0.83 0.93 1.03 1.14 1.27 1.41 1.57 1.74)
NAMES=("75pct" "83pct" "93pct" "103pct" "114pct" "127pct" "141pct" "157pct" "174pct")

RESULTS_DIR="/tmp/results-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR/_lb2"       # _lb2/ = second LB's output (fleet load, not parsed)

ANTAG_PID=""
ANTAG_LOG=""

echo "============================================="
echo " A/B Prequal vs RR — due passate, no contaminazione"
echo "============================================="
echo " Duration/step:   ${DURATION}s"
echo " Antagonist mode: ${MODE}"
echo " LB measured:     $LB1   (canonico)"
echo " LB co-load:      $LB2   (seconda metà della flotta)"
echo " Results dir:     $RESULTS_DIR"
echo

# --- Reachability -----------------------------------------------------------
for lb in "${LBS[@]}"; do
    if ! curl -fsS "$lb/health" >/dev/null; then
        echo "ERROR: $lb non raggiungibile" >&2
        exit 1
    fi
done
echo "Entrambi gli LB raggiungibili."
echo

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

# Set the same algorithm on BOTH LBs.
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

# Apply the heterogeneous static profile to the backends (static mode).
apply_static_profile() {
    echo "  → applico profilo statico: ${STATIC_LOADS[*]}"
    local pids=()
    for i in "${!BACKENDS[@]}"; do
        curl -fsS --max-time 2 \
            "http://${BACKENDS[$i]}:8080/admin/load?cpu=${STATIC_LOADS[$i]}" \
            >/dev/null 2>&1 &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
}

# Start the dynamic antagonist (dynamic mode), with the cycle aligned to the step:
# 6 states × INTERVAL = DURATION  →  each step covers exactly one full cycle,
# so Prequal and RR see the same average conditions.
start_antagonist() {
    local antag="$SCRIPT_DIR/dynamic-antagonist.sh"
    if [ ! -x "$antag" ]; then
        echo "ERROR: $antag non trovato/eseguibile (chmod +x dynamic-antagonist.sh)" >&2
        exit 1
    fi
    local interval=$(( DURATION / 6 ))
    [ "$interval" -lt 1 ] && interval=1
    ANTAG_LOG="/tmp/antagonist-ab-$(date +%Y%m%d-%H%M%S).log"
    echo "  → avvio antagonista dinamico (INTERVAL=${interval}s, ciclo=$((interval*6))s)"
    ANTAG_INTERVAL="$interval" ANTAG_LOG="$ANTAG_LOG" "$antag" &
    ANTAG_PID=$!
    sleep 3   # let it apply the first state
}

stop_antagonist() {
    if [ -n "$ANTAG_PID" ] && kill -0 "$ANTAG_PID" 2>/dev/null; then
        kill "$ANTAG_PID" 2>/dev/null || true
        wait "$ANTAG_PID" 2>/dev/null || true
        ANTAG_PID=""
    fi
}

cleanup() {
    stop_antagonist
}
trap cleanup EXIT INT TERM

# Extract "Requests/sec" from a hey output file.
req_per_sec() {
    grep -E "^[[:space:]]*Requests/sec:" "$1" 2>/dev/null | awk '{print $2}' | head -1
}

# ---------------------------------------------------------------------------
# Set up the backend conditions ONCE (they hold for discovery + both passes,
# so the A/B is fair).
# ---------------------------------------------------------------------------
if [ "$MODE" = "dynamic" ]; then
    start_antagonist
else
    apply_static_profile
fi
echo

# ---------------------------------------------------------------------------
# Saturation discovery — ONCE ONLY, common reference for both algorithms.
# We measure the ceiling with both LBs on RR (conservative baseline); the
# percentage levels are therefore relative to RR's saturation. Above 100% is
# the zone where Prequal must pull ahead.
# ---------------------------------------------------------------------------
echo "--- Saturation discovery (20s, uncapped, c=200, riferimento=RR) ---"
set_algo rr
sleep 5   # warm-up: let probes/threshold stabilize
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
echo

# Pre-compute the absolute QPS for each level (same for both passes).
QPS_TARGETS=()
for LEVEL in "${LEVELS[@]}"; do
    QPS_TARGETS+=( "$(awk -v s="$SAT_INT" -v l="$LEVEL" 'BEGIN{printf "%.0f", s*l}')" )
done

# ---------------------------------------------------------------------------
# One full pass: sets the algorithm on both LBs and runs the ramp.
# The CANONICAL (parsed) file is LB1's; LB2 provides the second half of the
# fleet load (output in _lb2/, ignored by parse-results.sh).
# ---------------------------------------------------------------------------
run_pass() {
    local ALGO="$1"
    echo "#############################################"
    echo "#  PASSATA: ${ALGO}  (entrambi gli LB)"
    echo "#############################################"
    set_algo "$ALGO"
    sleep 5   # warm-up after the switch: the RIF threshold is recomputed on the next probe
    echo

    for i in "${!LEVELS[@]}"; do
        local NAME=${NAMES[$i]}
        local QPS=${QPS_TARGETS[$i]}
        local QPS_PER_WORKER
        QPS_PER_WORKER=$(awk -v q="$QPS" -v c="$CONC" 'BEGIN{printf "%.4f", q/c}')

        echo "=== [$ALGO] Step $((i+1))/${#LEVELS[@]} — $NAME (target ${QPS} req/s per LB) ==="

        # NB: no "-t": a timeout truncates the tail (the signal Prequal wins
        # on lives at 2-4s under overload) and inflates/evens out throughput.
        hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" "$LB1" \
            > "$RESULTS_DIR/${ALGO}_${NAME}.txt"     2>&1 &
        local PID1=$!
        hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" "$LB2" \
            > "$RESULTS_DIR/_lb2/${ALGO}_${NAME}.txt" 2>&1 &
        local PID2=$!
        wait "$PID1" "$PID2"

        echo "  LB canonico (.11):"
        grep -E "Requests/sec|50%|95%|99%" "$RESULTS_DIR/${ALGO}_${NAME}.txt" \
            | head -4 | sed 's/^/      /'
        echo
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# The two passes
# ---------------------------------------------------------------------------
run_pass prequal

echo "--- cooldown 10s tra le due passate ---"
sleep 10

run_pass rr

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================="
echo "Esperimento A/B completo. Risultati in: $RESULTS_DIR"
if [ -x "$SCRIPT_DIR/parse-results.sh" ]; then
    echo "--- parse-results.sh ---"
    "$SCRIPT_DIR/parse-results.sh" "$RESULTS_DIR" || true
else
    echo "Parse con: ./parse-results.sh $RESULTS_DIR"
fi
[ -n "$ANTAG_LOG" ] && echo "Antagonist log: $ANTAG_LOG"
echo "============================================="
