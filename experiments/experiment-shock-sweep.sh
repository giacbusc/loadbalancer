#!/bin/bash
# experiment-shock-sweep.sh — Signal FRESHNESS sweep for experiment A.
#
# Runs experiment-shock.sh at multiple probe interval values IN ONE GO,
# changing the interval AT RUNTIME via /admin/probe-interval (curl, no SSH).
# All points share the same shock (HOT/COOL/NHOT from experiment-shock.sh
# defaults) and differ ONLY in signal freshness, so the comparison is clean.
#
# Requires the LB build with the /admin/probe-interval endpoint (runtime field
# in balancer.go + handler in cmd/server/main.go).
#
# Usage: ./experiment-shock-sweep.sh [nhot]
#   ./experiment-shock-sweep.sh           # intervals 250ms 1s 2s, NHOT=6
#   INTERVALS="250ms 500ms 1s 2s 4s" ./experiment-shock-sweep.sh 6
#
# Environment variables:
#   INTERVALS   list of probe intervals to test        (default "250ms 1s 2s")
#   SETTLE      wait after the interval change (s)     (default 8)
# All experiment-shock.sh env vars (HOT, COOL, BASE_LEVEL, ...) are propagated.

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

# Check that the runtime endpoints exist (up-to-date LB build).
if ! curl -fsS "$LB1/admin/probe-interval" >/dev/null 2>&1; then
    echo "ERROR: $LB1 non espone /admin/probe-interval." >&2
    echo "       Serve la build dell'LB con i campi runtime (balancer.go) + handler." >&2
    echo "       Re-instanzia o ricostruisci i container LB col codice aggiornato." >&2
    exit 1
fi

# RIF source for the WHOLE sweep (true = server-local, faithful to the paper
# and can go stale between probes; false = client-local real-time). Default: true.
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

    # 1. Set the interval on BOTH LBs.
    for lb in "${LBS[@]}"; do
        if ! curl -fsS "${lb}/admin/probe-interval?d=${IV}" >/dev/null; then
            echo "ERROR: impossibile impostare probe-interval=$IV su $lb" >&2
            exit 1
        fi
    done

    # 2. Wait for the ticker to reset (takes effect on the next tick) and for
    #    the probe pool to re-stabilize at the new pace.
    sleep "$SETTLE"

    # 3. Verify the active value on both (they must match).
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

    # 4. Launch the experiment (uses its defaults for HOT/COOL/DURATION/NHOT).
    #    experiment-shock.sh reads the probe interval from the LB and puts it in
    #    the directory name (_PI<iv>) and in meta.env, so runs stay distinguishable.
    "$SCRIPT_DIR/experiment-shock.sh" "${DURATION:-}" "$NHOT" \
        || { echo "ERRORE nel run a $IV" >&2; exit 1; }

    # Latest directory produced for this interval.
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
