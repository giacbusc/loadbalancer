#!/bin/bash
# dynamic-antagonist.sh — Rotate backend CPU loads every INTERVAL seconds.
#
# WHY:
#   Un antagonista statico testa Prequal vs RR in un solo punto operativo.
#   Con antagonisti dinamici il paesaggio di capacità cambia nel tempo:
#     - Server che erano lenti si "riprendono" improvvisamente
#     - Server clean diventano contesi
#   Prequal re-campiona la latenza ad ogni probe → si adatta in pochi secondi.
#   Round-Robin ignora lo stato dei server → continua a mandare traffico
#   ai server lenti anche dopo che sono tornati clean (e viceversa).
#   Questo amplifica la differenza osservabile tra i due algoritmi.
#
# COME FUNZIONA (senza riavviare Docker):
#   Il backend espone già /admin/load?cpu=VALUE (backend/main.go:255).
#   Questo script chiama quell'endpoint su tutti i server in parallelo con curl.
#
# ALLINEAMENTO CON L'ESPERIMENTO:
#   6 stati × 10s = ciclo di 60s = esattamente la durata di ogni step
#   dell'esperimento (default DURATION=60).
#   → ogni step dell'esperimento vede ESATTAMENTE un ciclo completo,
#     garantendo che Prequal e RR siano esposti alle stesse condizioni.
#
# WORKFLOW CONSIGLIATO:
#   # 1) Prima: verifica visiva che il ciclo funzioni
#   ./dynamic-antagonist.sh &
#   ./watch-backends.sh          # in un secondo terminale (tmux/screen)
#   # ... guarda i backend muoversi, poi fermalo
#   kill %1
#
#   # 2) Poi: lancia l'esperimento (il ciclo riparte automaticamente)
#   ./run-experiment.sh 60 dynamic
#
# VARIABILI D'AMBIENTE:
#   ANTAG_INTERVAL  secondi tra un cambio di stato (default: 10)
#   ANTAG_LOG       percorso del file di log (default: /tmp/antagonist-<ts>.log)

set -uo pipefail

INTERVAL="${ANTAG_INTERVAL:-5}"
PORT=8080
LOG="${ANTAG_LOG:-/tmp/antagonist-$(date +%Y%m%d-%H%M%S).log}"

# Backend IPs: server-0..9 → 10.10.1.21..30
SERVERS=(
    "10.10.1.21"   # server-0   (originalmente heavy)
    "10.10.1.22"   # server-1   (originalmente heavy)
    "10.10.1.23"   # server-2   (originalmente heavy)
    "10.10.1.24"   # server-3   (originalmente heavy)
    "10.10.1.25"   # server-4   (originalmente medium)
    "10.10.1.26"   # server-5   (originalmente medium)
    "10.10.1.27"   # server-6   (originalmente medium)
    "10.10.1.28"   # server-7   (originalmente clean)
    "10.10.1.29"   # server-8   (originalmente clean)
    "10.10.1.30"   # server-9   (originalmente clean)
)

# ---------------------------------------------------------------------------
# Mappatura cpu_load → burners attivi (backend/main.go, applyCPULoad):
#
#   cpu_load=0   → 0 burners  (clean)
#   cpu_load=150 → 3 burners  (medium)
#   cpu_load=300 → 6 burners  (heavy)
#   cpu_load=350 → 7 burners  (max — satura 7/8 core su m510)
#
# 6 STATI × 10s = CICLO DI 60s — corrisponde esattamente a DURATION per step.
# Ogni step dell'esperimento vede un ciclo completo identico → confronto equo.
#
# Valori: s0  s1  s2  s3    s4  s5  s6    s7  s8  s9
# ---------------------------------------------------------------------------

STATE_NAMES=(
    "BASELINE — 4×350 + 3×300 + 3×150  (carico distribuito pesante)"
    "SURGE    — 10×350                  (tutti al massimo assoluto)"
    "SHIFT    — s0..3 clean, s4..6 max, s7..9 heavy (inversione netta)"
    "RELIEF   — 3 server al massimo, il resto è clean"
    "STORM    — carico alternato 350/300 su tutti e 10 i server"
    "CALM     — 2 server pesanti, tutti gli altri clean"
)

# 10 valori per riga: s0 s1 s2 s3  s4 s5 s6  s7 s8 s9
STATES=(
    "350 350 350 350  300 300 300  150 150 150"   # 1 BASELINE
    "350 350 350 350  350 350 350  350 350 350"   # 2 SURGE    ← tutti al max
    "  0   0   0   0  350 350 350  300 300 300"   # 3 SHIFT    ← inversione netta
    "350 350 350   0    0   0   0    0   0   0"   # 4 RELIEF
    "350 300 350 300  350 300 350  300 350 300"   # 5 STORM    ← caos su tutti
    "350 350   0   0    0   0   0    0   0   0"   # 6 CALM
)

NUM_STATES=${#STATES[@]}

# ---------------------------------------------------------------------------
# Funzione: applica uno stato — chiama /admin/load su tutti i server
# in parallelo (curl con timeout 2s, errori ignorati silenziosamente)
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

    # Attendi tutti i curl in parallelo
    for pid in "${update_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

# Ripristina BASELINE all'uscita (Ctrl+C, kill, fine esperimento)
cleanup() {
    echo "" | tee -a "$LOG"
    echo "[$(date '+%H:%M:%S')] EXIT — ripristino BASELINE..." | tee -a "$LOG"
    apply_state 0
    echo "[$(date '+%H:%M:%S')] Ripristino completato. PID=$$ terminato." | tee -a "$LOG"
    exit 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Avvio
# ---------------------------------------------------------------------------
echo "=============================================" | tee -a "$LOG"
echo " Dynamic Antagonist — PID=$$"                 | tee -a "$LOG"
echo " Interval: ${INTERVAL}s | Stati: ${NUM_STATES} | Ciclo: $((INTERVAL*NUM_STATES))s" | tee -a "$LOG"
echo " Log: $LOG"                                   | tee -a "$LOG"
echo "=============================================" | tee -a "$LOG"
echo ""                                             | tee -a "$LOG"

# Applica subito BASELINE, poi cicla
apply_state 0
sleep "$INTERVAL"

state_idx=0
while true; do
    state_idx=$(( (state_idx + 1) % NUM_STATES ))
    apply_state "$state_idx"
    sleep "$INTERVAL"
done
