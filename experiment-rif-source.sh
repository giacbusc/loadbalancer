#!/bin/bash
# experiment-rif-source.sh — Compares HCL with client-local RIF vs server-local RIF.
#
# Run from a loadgen node. This experiment requires SSH-keying into the
# lb-prequal node to switch the LB_USE_SERVER_RIF env var between runs.
#
# Usage: ./experiment-rif-source.sh

set -e

DURATION=120
LB_PREQUAL_HOST="10.10.1.11"
LB_PREQUAL="http://${LB_PREQUAL_HOST}:8080"
RESULTS_DIR="/tmp/rif-source-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Helper: restart the LB container with a given LB_USE_SERVER_RIF value.
# Requires passwordless SSH to the LB host. CloudLab installs SSH keys for
# all members of your project, so this should work out of the box.
restart_lb() {
    local USE_SERVER_RIF="$1"
    echo ">> Restarting lb-prequal with LB_USE_SERVER_RIF=$USE_SERVER_RIF"
    ssh -o StrictHostKeyChecking=no "$LB_PREQUAL_HOST" \
        "sudo docker rm -f lb 2>/dev/null; \
         sudo docker run -d --name lb --restart=always --network host \
            -e LB_PORT=8080 \
            -e LB_ALGORITHM=prequal \
            -e LB_QRIF=0.84 \
            -e LB_SELECTION_CHOICES=2 \
            -e LB_PROBE_INTERVAL=1s \
            -e LB_USE_SERVER_RIF=$USE_SERVER_RIF \
            -e BACKENDS=10.10.1.21:8080,10.10.1.22:8080,10.10.1.23:8080,10.10.1.24:8080 \
            loadbalancer:latest"
    sleep 5
    # Wait for /health to come back.
    until curl -fsS "$LB_PREQUAL/health" >/dev/null; do
        echo "    waiting for LB to be ready..."
        sleep 2
    done
}

# Run a load test, output to a file.
run_load() {
    local LABEL="$1"
    local QPS="$2"
    echo ">> Running ${DURATION}s @ ${QPS}qps — label=$LABEL"
    hey -z "${DURATION}s" -q "$QPS" -c 50 "$LB_PREQUAL" \
        > "$RESULTS_DIR/${LABEL}.txt" 2>&1
    grep -E "Requests/sec|99%|95%|50%" "$RESULTS_DIR/${LABEL}.txt" | head -5 | sed 's/^/    /'
}

# Aim for a moderately stressed regime where the difference between
# client-local and server-local RIF should manifest.
QPS=300

restart_lb "false"
run_load "client_local" "$QPS"

restart_lb "true"
run_load "server_local" "$QPS"

echo
echo "Results in $RESULTS_DIR"
