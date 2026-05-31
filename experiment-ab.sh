#!/bin/bash
# experiment-ab.sh — A/B PULITO in due passate, senza contaminazione.
#
# IDEA (vedi discussione):
#   Invece di tenere accesi lb-prequal e lb-rr CONTEMPORANEAMENTE sugli stessi
#   backend (i due algoritmi si pestano: Prequal manda al server scarico mentre
#   RR lo inonda → il segnale di Prequal viene cancellato), facciamo DUE passate
#   separate, mettendo ENTRAMBI gli LB sullo stesso algoritmo via endpoint:
#
#     Passata 1:  .11 = prequal,  .12 = prequal   (flotta tutta-Prequal)
#     Passata 2:  .11 = rr,       .12 = rr        (flotta tutta-RR)
#
#   Dentro una passata il routing è OMOGENEO → niente contaminazione.
#   Si confronta poi Passata 1 vs Passata 2. È un vero A/B: stessi backend,
#   stesso antagonista, stesso carico; cambia solo l'algoritmo.
#
# L'algoritmo si cambia a runtime con /admin/algorithm?algo=prequal|rr
# (cmd/server/main.go:117) → niente redeploy tra le due passate.
#
# -----------------------------------------------------------------------------
# PREREQUISITO IMPORTANTE (per un confronto equo a favore di Prequal):
#   Gli LB dovrebbero girare con  LB_USE_SERVER_RIF=true  (env al boot,
#   cloudlab-setup.sh:99). Con due LB Prequal in parallelo e USE_SERVER_RIF=false
#   ogni LB conta solo il PROPRIO in-flight per server e non vede l'altro LB →
#   possono scegliere lo stesso server "scarico" e sovraccaricarlo insieme
#   (effetto gregge multi-LB). Con true ogni LB legge il RIF TOTALE riportato dal
#   backend (X-Server-RIF) e il segnale è completo. RR non ne risente.
#   Questo script NON può cambiarlo a runtime (è un env): verificalo prima.
# -----------------------------------------------------------------------------
#
# Usage: ./experiment-ab.sh [duration_per_step] [static|dynamic]
#   ./experiment-ab.sh              # 60s/step, antagonista STATICO eterogeneo
#   ./experiment-ab.sh 60 dynamic   # 60s/step, antagonista DINAMICO ciclico

set -uo pipefail

DURATION="${1:-60}"
MODE="${2:-static}"               # static | dynamic
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LB1="http://10.10.1.11:8080"
LB2="http://10.10.1.12:8080"
LBS=("$LB1" "$LB2")

# Backend server-0..9 → 10.10.1.21..30
BACKENDS=(10.10.1.21 10.10.1.22 10.10.1.23 10.10.1.24 10.10.1.25
          10.10.1.26 10.10.1.27 10.10.1.28 10.10.1.29 10.10.1.30)

# Profilo STATICO minoranza-carico: solo 3 server pesanti (350), 7 puliti (0),
# così Prequal ha sempre abbondante capacità dove dirottare. (cpu_load s0..s9)
# È lo scenario del paper: pochi antagonisti in mezzo a tante repliche sane.
STATIC_LOADS=(350 350 350 0 0 0 0 0 0 0)

CONC=1000                          # connessioni per LB
LEVELS=(0.75 0.83 0.93 1.03 1.14 1.27 1.41 1.57 1.74)
NAMES=("75pct" "83pct" "93pct" "103pct" "114pct" "127pct" "141pct" "157pct" "174pct")

RESULTS_DIR="/tmp/results-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR/_lb2"       # _lb2/ = output del secondo LB (carico di flotta, non parsato)

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

# Imposta lo stesso algoritmo su ENTRAMBI gli LB.
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

# Applica il profilo statico eterogeneo ai backend (modalità static).
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

# Avvia l'antagonista dinamico (modalità dynamic), con ciclo allineato allo step:
# 6 stati × INTERVAL = DURATION  →  ogni step copre esattamente un ciclo intero,
# così Prequal e RR vedono la stessa media di condizioni.
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
    sleep 3   # lascia applicare il primo stato
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

# Estrae "Requests/sec" da un file hey.
req_per_sec() {
    grep -E "^[[:space:]]*Requests/sec:" "$1" 2>/dev/null | awk '{print $2}' | head -1
}

# ---------------------------------------------------------------------------
# Setup condizioni backend UNA VOLTA SOLA (valgono per discovery + entrambe le
# passate, così l'A/B è equo).
# ---------------------------------------------------------------------------
if [ "$MODE" = "dynamic" ]; then
    start_antagonist
else
    apply_static_profile
fi
echo

# ---------------------------------------------------------------------------
# Saturation discovery — UNA SOLA VOLTA, riferimento comune ai due algoritmi.
# Misuriamo il soffitto con entrambi gli LB su RR (baseline conservativa); i
# livelli percentuali sono quindi relativi alla saturazione di RR. Prequal sopra
# il 100% è la zona dove deve staccarsi.
# ---------------------------------------------------------------------------
echo "--- Saturation discovery (20s, uncapped, c=200, riferimento=RR) ---"
set_algo rr
sleep 5   # warm-up: lascia stabilizzare probe/soglia
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

# Pre-calcola il QPS assoluto per ogni livello (uguale per entrambe le passate).
QPS_TARGETS=()
for LEVEL in "${LEVELS[@]}"; do
    QPS_TARGETS+=( "$(awk -v s="$SAT_INT" -v l="$LEVEL" 'BEGIN{printf "%.0f", s*l}')" )
done

# ---------------------------------------------------------------------------
# Una passata completa: imposta l'algoritmo su entrambi gli LB e fa il ramp.
# Il file CANONICO (parsato) è quello di LB1; LB2 fornisce la seconda metà del
# carico di flotta (output in _lb2/, ignorato da parse-results.sh).
# ---------------------------------------------------------------------------
run_pass() {
    local ALGO="$1"
    echo "#############################################"
    echo "#  PASSATA: ${ALGO}  (entrambi gli LB)"
    echo "#############################################"
    set_algo "$ALGO"
    sleep 5   # warm-up dopo lo switch: la soglia RIF si ricalcola al probe successivo
    echo

    for i in "${!LEVELS[@]}"; do
        local NAME=${NAMES[$i]}
        local QPS=${QPS_TARGETS[$i]}
        local QPS_PER_WORKER
        QPS_PER_WORKER=$(awk -v q="$QPS" -v c="$CONC" 'BEGIN{printf "%.4f", q/c}')

        echo "=== [$ALGO] Step $((i+1))/${#LEVELS[@]} — $NAME (target ${QPS} req/s per LB) ==="

        # NB: niente "-t": un timeout tronca la coda (il segnale su cui Prequal
        # vince vive a 2-4s sotto overload) e gonfia/pareggia il throughput.
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
# Le due passate
# ---------------------------------------------------------------------------
run_pass prequal

echo "--- cooldown 10s tra le due passate ---"
sleep 10

run_pass rr

# ---------------------------------------------------------------------------
# Riepilogo
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
