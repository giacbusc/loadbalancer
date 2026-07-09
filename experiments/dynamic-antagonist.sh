#!/bin/bash
# dynamic-antagonist.sh — Rotate backend CPU loads every INTERVAL seconds.
#
# WHY:
#   A static antagonist tests Prequal vs RR at a single operating point.
#   With dynamic antagonists the capacity landscape changes over time:
#     - Servers that were slow suddenly "recover"
#     - Clean servers become contended
#   Prequal re-samples latency on every probe → it adapts within seconds.
#   Round-Robin ignores server state → it keeps sending traffic to slow
#   servers even after they have become clean again (and vice versa).
#   This amplifies the observable difference between the two algorithms.
#
# HOW IT WORKS (no Docker restart needed):
#   The backend already exposes /admin/load?cpu=VALUE (backend/main.go:255).
#   This script calls that endpoint on all servers in parallel via curl.
#
# ALIGNMENT WITH THE EXPERIMENT:
#   6 states × 10s = 60s cycle = exactly the duration of each experiment
#   step (default DURATION=60).
#   → every experiment step sees EXACTLY one full cycle, guaranteeing
#     that Prequal and RR are exposed to the same conditions.
#
# RECOMMENDED WORKFLOW:
#   # 1) First: visually verify that the cycle works
#   ./dynamic-antagonist.sh &
#   ./watch-backends.sh          # in a second terminal (tmux/screen)
#   # ... watch the backends change, then stop it
#   kill %1
#
#   # 2) Then: launch the experiment (the cycle restarts automatically)
#   ./run-experiment.sh 60 dynamic
#
# ENVIRONMENT VARIABLES:
#   ANTAG_INTERVAL  seconds between state changes (default: 10)
#   ANTAG_LOG       log file path (default: /tmp/antagonist-<ts>.log)

set -uo pipefail

INTERVAL="${ANTAG_INTERVAL:-5}"
PORT=8080
LOG="${ANTAG_LOG:-/tmp/antagonist-$(date +%Y%m%d-%H%M%S).log}"

# Backend IPs: server-0..9 → 10.10.1.21..30
SERVERS=(
    "10.10.1.21"   # server-0   (originally heavy)
    "10.10.1.22"   # server-1   (originally heavy)
    "10.10.1.23"   # server-2   (originally heavy)
    "10.10.1.24"   # server-3   (originally heavy)
    "10.10.1.25"   # server-4   (originally medium)
    "10.10.1.26"   # server-5   (originally medium)
    "10.10.1.27"   # server-6   (originally medium)
    "10.10.1.28"   # server-7   (originally clean)
    "10.10.1.29"   # server-8   (originally clean)
    "10.10.1.30"   # server-9   (originally clean)
)

# ---------------------------------------------------------------------------
# Mapping cpu_load → active burners (backend/main.go, applyCPULoad):
#
#   cpu_load=0   → 0 burners  (clean)
#   cpu_load=150 → 3 burners  (medium)
#   cpu_load=300 → 6 burners  (heavy)
#   cpu_load=350 → 7 burners  (max — saturates 7/8 cores on m510)
#
# 6 STATES × 10s = 60s CYCLE — matches the per-step DURATION exactly.
# Every experiment step sees one identical full cycle → fair comparison.
#
# Values: s0  s1  s2  s3    s4  s5  s6    s7  s8  s9
# ---------------------------------------------------------------------------

# MINORITY-LOAD: in each state only 2-3 servers are hot (350 = 7 burners),
# the rest are clean (0). The hot servers MOVE over time, so RR keeps
# hitting them while Prequal always has 7-8 free servers to divert to.
# This is the paper's scenario: a few antagonists among many healthy replicas.
STATE_NAMES=(
    "HEAD   — 3 caldi a inizio fila (s0,s1,s2), resto pulito"
    "MID    — 3 caldi al centro (s3,s4,s5), resto pulito"
    "TAIL   — 3 caldi in coda (s7,s8,s9), resto pulito"
    "SPARSE — 3 caldi sparsi (s0,s4,s8), resto pulito"
    "PAIR   — 2 caldi (s2,s3), resto pulito"
    "PAIR2  — 2 caldi (s6,s7), resto pulito"
)

# 10 values per row: s0 s1 s2 s3  s4 s5 s6  s7 s8 s9   (350 = hot, 0 = clean)
STATES=(
    "350 350 350   0    0   0   0    0   0   0"   # 1 HEAD
    "  0   0   0 350  350 350   0    0   0   0"   # 2 MID
    "  0   0   0   0    0   0   0  350 350 350"   # 3 TAIL
    "350   0   0   0  350   0   0    0 350   0"   # 4 SPARSE
    "  0   0 350 350    0   0   0    0   0   0"   # 5 PAIR
    "  0   0   0   0    0   0 350  350   0   0"   # 6 PAIR2
)

NUM_STATES=${#STATES[@]}

# ---------------------------------------------------------------------------
# Apply a state — calls /admin/load on all servers in parallel
# (curl with a 2s timeout, errors silently ignored)
# ---------------------------------------------------------------------------
apply_state() {
    local idx=$1
    read -ra loads <<< "${STATES[$idx]}"
    local name="${STATE_NAMES[$idx]}"

    echo "[$(date '+%H:%M:%S')] Stato $((idx+1))/${NUM_STATES}: ${name}" | tee -a "$LOG"

    local update_pids=()
    for i in "${!SERVERS[@]}"; do
        local ip="${SERVERS[$i]}"
        local load="${loads[$i]:-0}"
        curl -fsS --max-time 2 \
             "http://${ip}:${PORT}/admin/load?cpu=${load}" \
             >> "$LOG" 2>&1 &
        update_pids+=($!)
    done

    # Wait for all parallel curl calls to finish
    for pid in "${update_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

# Restore BASELINE on exit (Ctrl+C, kill, end of experiment)
cleanup() {
    echo "" | tee -a "$LOG"
    echo "[$(date '+%H:%M:%S')] EXIT — ripristino BASELINE..." | tee -a "$LOG"
    apply_state 0
    echo "[$(date '+%H:%M:%S')] Ripristino completato. PID=$$ terminato." | tee -a "$LOG"
    exit 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
echo "=============================================" | tee -a "$LOG"
echo " Dynamic Antagonist — PID=$$"                 | tee -a "$LOG"
echo " Interval: ${INTERVAL}s | Stati: ${NUM_STATES} | Ciclo: $((INTERVAL*NUM_STATES))s" | tee -a "$LOG"
echo " Log: $LOG"                                   | tee -a "$LOG"
echo "=============================================" | tee -a "$LOG"
echo ""                                             | tee -a "$LOG"

# Apply BASELINE immediately, then cycle
apply_state 0
sleep "$INTERVAL"

state_idx=0
while true; do
    state_idx=$(( (state_idx + 1) % NUM_STATES ))
    apply_state "$state_idx"
    sleep "$INTERVAL"
done
