#!/bin/bash
# experiment-shock.sh — RISPOSTA TRANSITORIA a uno shock correlato (esperimento A).
#
# MOTIVAZIONE (further exploration, va OLTRE il paper):
#   Tutti gli esperimenti del paper (e i nostri finora) misurano il sistema a
#   REGIME: un punto di equilibrio per ogni livello di carico, tail-latency vs
#   load. Il paper non guarda MAI il DOMINIO DEL TEMPO:
#     1. quanto velocemente ciascuna policy REAGISCE a uno shock improvviso, e
#     2. quanto tempo ci mette a RECUPERARE dopo che lo shock finisce.
#   Inoltre il paper assume sempre l'esistenza di una "maggioranza fredda" su cui
#   Prequal può dirottare. Qui colpiamo NHOT backend su 10 CONTEMPORANEAMENTE (uno
#   shock CORRELATO, non i nostri antagonisti indipendenti) e, variando NHOT,
#   troviamo il punto in cui quella maggioranza fredda sparisce e il vantaggio di
#   Prequal svanisce ("no escape" regime).
#
# COME (senza stravolgere nulla):
#   - Carico COSTANTE (BASE_LEVEL × saturazione) per tutta la passata, come in
#     experiment-ab.sh, con discovery di saturazione una volta sola su RR.
#   - Onda quadra di antagonista: WARMUP, poi ON (NHOT backend a SHOCK_LOAD) per
#     HOT secondi, OFF (tutti puliti) per COOL secondi, ripetuto NCYCLES volte.
#     Ogni ciclo è un evento di shock ripetuto → ensemble averaging in plot.
#   - hey viene lanciato con "-o csv": dà OGNI richiesta con (response-time,offset)
#     così plot_shock.py può binnare a 0.5s e ricostruire p99(t). L'aggregato dei
#     60s di hey, da solo, spalmerebbe il transitorio e lo renderebbe invisibile.
#   - A/B in due passate identiche (tutta-Prequal, tutta-RR) come experiment-ab.sh,
#     via /admin/algorithm a runtime: stesso schedule di shock, cambia solo l'algo.
#
# Usage: ./experiment-shock.sh [duration_per_pass] [nhot]
#   ./experiment-shock.sh                 # 108s/passata (8 cicli), 6 backend colpiti
#   ./experiment-shock.sh 108 4           # 108s/passata, 4 backend colpiti
#   NHOT sweep (regime "no escape"):
#   for n in 2 4 6 8; do ./experiment-shock.sh 108 $n; done
#   Shock lungo (vecchio default): HOT=8 COOL=12 ./experiment-shock.sh 180 6
#
# Variabili d'ambiente (override opzionale):
#   BASE_LEVEL  carico costante in frazione di saturazione        (default 1.00)
#   HOT         secondi di shock ON  (shock corto per isolare il lag)  (default 3)
#   COOL        secondi di recupero OFF                            (default 9)
#   WARMUP      secondi prima del primo shock                      (default 12)
#   SHOCK_LOAD  cpu_load applicato ai backend colpiti             (default 350)
#   CONC        connessioni per LB                                (default 1000)

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

# Backend server-0..9 → 10.10.1.21..30 (stessi di experiment-ab.sh)
BACKENDS=(10.10.1.21 10.10.1.22 10.10.1.23 10.10.1.24 10.10.1.25
          10.10.1.26 10.10.1.27 10.10.1.28 10.10.1.29 10.10.1.30)

PERIOD=$(( HOT + COOL ))
NCYCLES=$(awk -v d="$DURATION" -v w="$WARMUP" -v p="$PERIOD" 'BEGIN{printf "%d", (d-w)/p}')

RESULTS_DIR="/tmp/results-shock-$(date +%Y%m%d-%H%M%S)_NHOT${NHOT}"
mkdir -p "$RESULTS_DIR/_lb2"

T0=""   # impostato per-passata appena prima di lanciare hey

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

# Probe interval ATTIVO letto dall'LB (GET /admin/probe-interval), così la
# cartella e meta.env sono auto-documentanti per lo sweep di freschezza.
# Se l'LB è una build vecchia senza endpoint, ripiega su "unknown".
PROBE_IV=$(curl -fsS "$LB1/admin/probe-interval" 2>/dev/null | tr -d '[:space:]')
[ -z "$PROBE_IV" ] && PROBE_IV="unknown"
# Sorgente RIF attiva: true = server-local (probe, stale-abile), false = client-local (real-time).
RIF_SRC=$(curl -fsS "$LB1/admin/use-server-rif" 2>/dev/null | tr -d '[:space:]')
[ -z "$RIF_SRC" ] && RIF_SRC="unknown"
RIF_TAG="srv"; [ "$RIF_SRC" = "false" ] && RIF_TAG="loc"
NEW_DIR="${RESULTS_DIR}_PI${PROBE_IV}_RIF${RIF_TAG}"
mv "$RESULTS_DIR" "$NEW_DIR" && RESULTS_DIR="$NEW_DIR"
echo "Probe interval attivo: ${PROBE_IV} | use_server_rif: ${RIF_SRC}"
echo "Results dir: $RESULTS_DIR"
echo

# ---------------------------------------------------------------------------
# Helper (stessi di experiment-ab.sh)
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

# Porta TUTTI i backend a cpu_load=0 (in parallelo).
reset_clean() {
    local pids=()
    for ip in "${BACKENDS[@]}"; do
        curl -fsS --max-time 2 "http://${ip}:8080/admin/load?cpu=0" >/dev/null 2>&1 &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
}

# Applica un valore di cpu_load ai PRIMI NHOT backend (in parallelo).
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

# Registra un fronte (ON/OFF) col tempo trascorso da T0 (= istante di start di hey).
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
# Saturation discovery — UNA SOLA VOLTA, su RR (riferimento comune).
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

# Metadati per il plotter (lettura key=value).
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
# Una passata: imposta l'algoritmo, lancia hey a carico costante con -o csv,
# e in parallelo guida l'onda quadra di shock loggando i fronti.
# ---------------------------------------------------------------------------
run_pass() {
    local ALGO="$1"
    echo "#############################################"
    echo "#  PASSATA: ${ALGO}  (entrambi gli LB)"
    echo "#############################################"
    set_algo "$ALGO"
    sleep 5            # warm-up dopo lo switch: la soglia RIF si ricalcola al probe successivo
    reset_clean
    sleep 2

    local edgelog="$RESULTS_DIR/${ALGO}_edges.log"
    : > "$edgelog"

    # T0 = istante di start di hey; gli offset di hey -o csv sono relativi a qui.
    T0=$(date +%s.%N)

    # LB canonico (.11) → CSV per-richiesta (parsato da plot_shock.py).
    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" -o csv "$LB1" \
        > "$RESULTS_DIR/${ALGO}.csv" 2>"$RESULTS_DIR/${ALGO}.err" &
    local HPID=$!
    # LB co-load (.12) → seconda metà del carico di flotta (output ignorato).
    hey -z "${DURATION}s" -q "$QPS_PER_WORKER" -c "$CONC" "$LB2" \
        > "$RESULTS_DIR/_lb2/${ALGO}.txt" 2>&1 &
    local HPID2=$!

    # Onda quadra di shock, sincronizzata con hey via T0.
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
# Le due passate
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