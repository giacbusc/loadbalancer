#!/bin/bash
# experiment-shock-sweep.sh — Sweep di FRESCHEZZA del segnale per l'esperimento A.
#
# Esegue experiment-shock.sh a più valori di probe interval IN UN COLPO SOLO,
# cambiando l'intervallo A RUNTIME via /admin/probe-interval (curl, niente SSH).
# Tutti i punti condividono lo stesso shock (HOT/COOL/NHOT dai default di
# experiment-shock.sh) e differiscono SOLO per la freschezza del segnale, così
# il confronto è pulito.
#
# Richiede la build dell'LB con l'endpoint /admin/probe-interval (campo runtime
# in balancer.go + handler in cmd/server/main.go).
#
# Usage: ./experiment-shock-sweep.sh [nhot]
#   ./experiment-shock-sweep.sh           # intervalli 250ms 1s 2s, NHOT=6
#   INTERVALS="250ms 500ms 1s 2s 4s" ./experiment-shock-sweep.sh 6
#
# Variabili d'ambiente:
#   INTERVALS   lista di probe interval da testare   (default "250ms 1s 2s")
#   SETTLE      attesa dopo il cambio interval (s)    (default 8)
# Tutte le env di experiment-shock.sh (HOT, COOL, BASE_LEVEL, ...) sono propagate.

set -uo pipefail

NHOT="${1:-6}"
INTERVALS="${INTERVALS:-250ms 1s 2s}"
SETTLE="${SETTLE:-8}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LB1="http://10.10.1.11:8080"
LB2="http://10.10.1.12:8080"
LBS=("$LB1" "$LB2")

echo "============================================="
echo " Shock freshness sweep — probe interval = [$INTERVALS]"
echo "============================================="
echo " NHOT: $NHOT | settle: ${SETTLE}s | shock: HOT=${HOT:-default} COOL=${COOL:-default}"
echo

# Verifica che gli endpoint runtime esistano (build aggiornata dell'LB).
if ! curl -fsS "$LB1/admin/probe-interval" >/dev/null 2>&1; then
    echo "ERROR: $LB1 non espone /admin/probe-interval." >&2
    echo "       Serve la build dell'LB con i campi runtime (balancer.go) + handler." >&2
    echo "       Re-instanzia o ricostruisci i container LB col codice aggiornato." >&2
    exit 1
fi

# Sorgente RIF per TUTTO lo sweep (true = server-local, fedele al paper e
# stale-abile dal probe; false = client-local real-time). Default: true.
USE_SERVER_RIF="${USE_SERVER_RIF:-true}"
if curl -fsS "$LB1/admin/use-server-rif" >/dev/null 2>&1; then
    for lb in "${LBS[@]}"; do
        curl -fsS "${lb}/admin/use-server-rif?v=${USE_SERVER_RIF}" >/dev/null \
            || { echo "ERROR: impossibile impostare use-server-rif su $lb" >&2; exit 1; }
    done
    echo "use_server_rif impostato a '$USE_SERVER_RIF' su tutti gli LB"
    echo
else
    echo "ATTENZIONE: /admin/use-server-rif non disponibile (build vecchia)." >&2
    echo "            Il valore resta quello di boot; verifica che sia '$USE_SERVER_RIF'." >&2
fi

RESULT_DIRS=()

for IV in $INTERVALS; do
    echo "#############################################"
    echo "#  Probe interval = $IV"
    echo "#############################################"

    # 1. Imposta l'intervallo su ENTRAMBI gli LB.
    for lb in "${LBS[@]}"; do
        if ! curl -fsS "${lb}/admin/probe-interval?d=${IV}" >/dev/null; then
            echo "ERROR: impossibile impostare probe-interval=$IV su $lb" >&2
            exit 1
        fi
    done

    # 2. Attendi che il ticker si resetti (effetto al tick successivo) e che la
    #    pool di probe si ristabilizzi al nuovo ritmo.
    sleep "$SETTLE"

    # 3. Verifica il valore attivo su entrambi (deve combaciare).
    ok=1
    for lb in "${LBS[@]}"; do
        got=$(curl -fsS "${lb}/admin/probe-interval" | tr -d '[:space:]')
        echo "  $lb → probe interval attivo: $got"
        [ "$got" != "$IV" ] && ok=0
    done
    if [ "$ok" != 1 ]; then
        echo "  ATTENZIONE: valore attivo diverso da '$IV' — aumenta SETTLE o controlla l'LB." >&2
    fi
    echo

    # 4. Lancia l'esperimento (usa i suoi default per HOT/COOL/DURATION/NHOT).
    #    experiment-shock.sh legge il probe interval dall'LB e lo mette nel nome
    #    cartella (_PI<iv>) e in meta.env, quindi i run restano distinguibili.
    "$SCRIPT_DIR/experiment-shock.sh" "${DURATION:-}" "$NHOT" \
        || { echo "ERRORE nel run a $IV" >&2; exit 1; }

    # Ultima cartella prodotta per questo intervallo.
    LAST=$(ls -dt /tmp/results-shock-*_NHOT${NHOT}_PI* 2>/dev/null | head -1)
    [ -n "$LAST" ] && RESULT_DIRS+=("$LAST")
    echo
done

echo "============================================="
echo "Sweep completo. Cartelle prodotte:"
for d in "${RESULT_DIRS[@]}"; do echo "  $d"; done
echo
echo "Per scaricarle in locale (dal Mac):"
echo "  scp -r 'giacbusc@ms1327.utah.cloudlab.us:/tmp/results-shock-*_NHOT${NHOT}_PI*' ~/Documents/GitHub/loadbalancer/"
echo "============================================="
