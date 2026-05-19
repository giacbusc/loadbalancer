#!/bin/bash
# deploy.sh — pull latest code on every CloudLab node and restart containers.
#
# Run from your LOCAL machine (not from a CloudLab node).
# Requires that your SSH key is loaded and that CloudLab nodes are reachable.
#
# Usage:
#   ./deploy.sh              # pull + restart all nodes
#   ./deploy.sh obs          # only obs node (e.g. to reload Grafana dashboard)
#   ./deploy.sh backends     # only the 10 backend nodes
#   ./deploy.sh lbs          # only the 2 LB nodes

set -e

OBS="10.10.1.10"
LB_PREQUAL="10.10.1.11"
LB_RR="10.10.1.12"
BACKENDS=(10.10.1.21 10.10.1.22 10.10.1.23 10.10.1.24 10.10.1.25
          10.10.1.26 10.10.1.27 10.10.1.28 10.10.1.29 10.10.1.30)
LOADGENS=(10.10.1.31 10.10.1.32)

WORKDIR="/opt/loadbalancer"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_ssh() {
    local host="$1"; shift
    ssh $SSH_OPTS "$host" "$@"
}

pull_and_log() {
    local host="$1"
    echo "[${host}] git pull..."
    run_ssh "$host" "cd $WORKDIR && sudo git pull --ff-only" &
}

wait_all() { wait; echo "--- all done ---"; }

# ---------------------------------------------------------------------------
# Per-role restart commands (executed AFTER git pull)
# ---------------------------------------------------------------------------

restart_obs() {
    echo "[obs] restarting Grafana..."
    run_ssh "$OBS" "sudo docker restart grafana"
}

restart_lb_prequal() {
    echo "[lb-prequal] rebuilding + restarting lb..."
    run_ssh "$LB_PREQUAL" "
        cd $WORKDIR &&
        sudo docker build -t loadbalancer:latest -f Dockerfile . &&
        sudo docker restart lb
    "
}

restart_lb_rr() {
    echo "[lb-rr] rebuilding + restarting lb..."
    run_ssh "$LB_RR" "
        cd $WORKDIR &&
        sudo docker build -t loadbalancer:latest -f Dockerfile . &&
        sudo docker restart lb
    "
}

restart_backend() {
    local host="$1"
    echo "[${host}] rebuilding + restarting backend..."
    run_ssh "$host" "
        cd $WORKDIR &&
        sudo docker build -t backend:latest -f backend/Dockerfile ./backend &&
        sudo docker restart backend
    " &
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

TARGET="${1:-all}"

case "$TARGET" in

  obs)
    pull_and_log "$OBS"; wait_all
    restart_obs
    ;;

  lbs)
    pull_and_log "$LB_PREQUAL"
    pull_and_log "$LB_RR"
    wait_all
    restart_lb_prequal &
    restart_lb_rr &
    wait_all
    ;;

  backends)
    for h in "${BACKENDS[@]}"; do pull_and_log "$h"; done
    wait_all
    for h in "${BACKENDS[@]}"; do restart_backend "$h"; done
    wait_all
    ;;

  all)
    # 1. Pull everywhere in parallel
    pull_and_log "$OBS"
    pull_and_log "$LB_PREQUAL"
    pull_and_log "$LB_RR"
    for h in "${BACKENDS[@]}"; do pull_and_log "$h"; done
    for h in "${LOADGENS[@]}"; do pull_and_log "$h"; done
    wait_all

    # 2. Restart containers (obs and LBs are quick; backends in parallel)
    restart_obs
    restart_lb_prequal &
    restart_lb_rr &
    for h in "${BACKENDS[@]}"; do restart_backend "$h"; done
    wait_all
    ;;

  *)
    echo "Usage: $0 [all|obs|lbs|backends]"
    exit 1
    ;;
esac

echo "Deploy complete."
