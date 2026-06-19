#!/bin/bash
# set-probe-interval.sh — Ricrea il container LB sui due nodi load balancer con un
# nuovo LB_PROBE_INTERVAL, SENZA toccare il resto dell'esperimento CloudLab
# (backend, obs, loadgen restano intatti).
#
# PERCHE':
#   LB_PROBE_INTERVAL è "cotto" al momento della docker run (cloudlab-setup.sh:98),
#   quindi `docker restart` riuserebbe il vecchio valore: serve rm -f + run.
#   Questo script automatizza il rm+run via ssh su .11 e .12 in un colpo solo, così
#   lo sweep di freschezza per experiment-shock.sh diventa:
#       ./set-probe-interval.sh 1s && ./experiment-shock.sh 180 6
#
# DOVE LANCIARLO:
#   Da un nodo sulla LAN dell'esperimento (es. loadgen-0, 10.10.1.31), che ha
#   ssh senza password verso gli altri nodi e raggiunge gli LB su :8080.
#
# Usage: ./set-probe-interval.sh <interval> [algo]
#   ./set-probe-interval.sh 1s              # 1s, algo=prequal
#   ./set-probe-interval.sh 250ms           # torna al baseline deployato
#   ./set-probe-interval.sh 2s roundrobin   # (l'A/B sovrascrive comunque l'algo a runtime)
#
# Variabili d'ambiente (override opzionale):
#   LB_HOSTS         host degli LB                         (default "10.10.1.11 10.10.1.12")
#   SSH_USER         utente ssh (vuoto = utente corrente)  (default vuoto)
#   DOCKER           comando docker remoto                 (default "sudo docker")
#   QRIF             quantile hot/cold                      (default 0.84)
#   CHOICES          d in Power-of-d-Choices               (default 2)
#   USE_SERVER_RIF   RIF server-local (coerente con A/B)    (default true)
#   IMAGE            immagine LB già buildata sui nodi      (default loadbalancer:latest)

set -uo pipefail

INTERVAL="${1:?Uso: ./set-probe-interval.sh <interval> [algo]   es. ./set-probe-interval.sh 1s}"
ALGO="${2:-prequal}"

LB_HOSTS="${LB_HOSTS:-10.10.1.11 10.10.1.12}"
SSH_USER="${SSH_USER:-}"
DOCKER="${DOCKER:-sudo docker}"
QRIF="${QRIF:-0.84}"
CHOICES="${CHOICES:-2}"
USE_SERVER_RIF="${USE_SERVER_RIF:-true}"
IMAGE="${IMAGE:-loadbalancer:latest}"

# Stessa lista backend di cloudlab-setup.sh.
BACKENDS="10.10.1.21:8080,10.10.1.22:8080,10.10.1.23:8080,10.10.1.24:8080,10.10.1.25:8080,10.10.1.26:8080,10.10.1.27:8080,10.10.1.28:8080,10.10.1.29:8080,10.10.1.30:8080"

ssh_target() { [ -n "$SSH_USER" ] && echo "${SSH_USER}@$1" || echo "$1"; }

echo "============================================="
echo " set-probe-interval — LB_PROBE_INTERVAL=$INTERVAL"
echo "============================================="
echo " Host LB:        $LB_HOSTS"
echo " Algoritmo:      $ALGO"
echo " USE_SERVER_RIF: $USE_SERVER_RIF | QRIF: $QRIF | CHOICES: $CHOICES"
echo

# --- Ricrea il container su ogni nodo LB ------------------------------------
for host in $LB_HOSTS; do
    tgt=$(ssh_target "$host")
    echo "→ ricreo 'lb' su $host"
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$tgt" "
        $DOCKER rm -f lb >/dev/null 2>&1 || true
        $DOCKER run -d --name lb --restart=always --network host \
            -e LB_PORT=8080 \
            -e LB_ALGORITHM='$ALGO' \
            -e LB_QRIF=$QRIF \
            -e LB_SELECTION_CHOICES=$CHOICES \
            -e LB_PROBE_INTERVAL='$INTERVAL' \
            -e LB_USE_SERVER_RIF=$USE_SERVER_RIF \
            -e BACKENDS='$BACKENDS' \
            $IMAGE >/dev/null
    "; then
        echo "  ✓ container avviato"
    else
        echo "  ✗ ERRORE su $host (controlla ssh/sudo/docker)" >&2
        exit 1
    fi
done

# --- Attendi che gli LB tornino healthy -------------------------------------
echo
echo "Attendo che gli LB tornino healthy (la pool di probe si ripopola)..."
for host in $LB_HOSTS; do
    ok=0
    for _ in $(seq 1 20); do
        if curl -fsS --max-time 2 "http://${host}:8080/health" >/dev/null 2>&1; then
            ok=1; break
        fi
        sleep 1
    done
    if [ "$ok" = 1 ]; then
        echo "  ✓ $host healthy"
    else
        echo "  ✗ ATTENZIONE: $host non healthy dopo 20s" >&2
    fi
done

# --- Riepilogo --------------------------------------------------------------
FIRST_HOST="${LB_HOSTS%% *}"
echo
echo "Fatto. L'LB logga l'intervallo attivo allo start; verificalo con:"
echo "  ssh $(ssh_target "$FIRST_HOST") \"$DOCKER logs lb 2>&1 | grep -i probe_interval\""
echo
echo "Ora lancia l'esperimento, es:"
echo "  ./experiment-shock.sh 180 6"
echo "============================================="
