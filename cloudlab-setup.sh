#!/bin/bash
# cloudlab-setup.sh — runs once at boot on each CloudLab node.
# Usage: sudo bash cloudlab-setup.sh <role> <repo_url> <branch> [extra_arg]
#
# Roles:
#   obs            -> Prometheus + Grafana
#   lb-prequal     -> Load balancer (Prequal algorithm)
#   lb-rr          -> Load balancer (Round-Robin algorithm)
#   backend        -> Backend server. extra_arg = cpu_load (0..400)
#   loadgen        -> Load generator (installs hey)

set -e

ROLE="${1:?role required}"
REPO_URL="${2:?repo_url required}"
BRANCH="${3:-main}"
EXTRA="${4:-0}"
WORKDIR="/opt/loadbalancer"

echo "==> Cloudlab setup starting (role=$ROLE, extra=$EXTRA)"
date

# --- 1. Install Docker --------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "==> Installing Docker"
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
fi

# --- 2. Tooling ---------------------------------------------------------------
apt-get install -y git stress-ng jq htop

# --- 3. Clone repo ------------------------------------------------------------
if [ ! -d "$WORKDIR" ]; then
    git clone --branch "$BRANCH" "$REPO_URL" "$WORKDIR"
else
    cd "$WORKDIR" && git pull
fi
cd "$WORKDIR"

# --- 4. Per-role startup ------------------------------------------------------
case "$ROLE" in

  obs)
    cat > /tmp/prometheus.yml <<'EOF'
global:
  scrape_interval: 5s
  evaluation_interval: 5s
scrape_configs:
  - job_name: 'lb-prequal'
    static_configs:
      - targets: ['10.10.1.11:8080']
    metrics_path: '/metrics'
  - job_name: 'lb-rr'
    static_configs:
      - targets: ['10.10.1.12:8080']
    metrics_path: '/metrics'
EOF
    docker rm -f prometheus grafana 2>/dev/null || true
    docker run -d --name prometheus --restart=always \
        -p 9090:9090 \
        -v /tmp/prometheus.yml:/etc/prometheus/prometheus.yml \
        prom/prometheus
    docker run -d --name grafana --restart=always \
        -p 3001:3000 \
        -e GF_SECURITY_ADMIN_USER=admin \
        -e GF_SECURITY_ADMIN_PASSWORD=admin \
        grafana/grafana
    ;;

  lb-prequal|lb-rr)
    ALGO="prequal"
    [ "$ROLE" = "lb-rr" ] && ALGO="roundrobin"

    # All 10 backends, port 8080 each.
    BACKENDS="10.10.1.21:8080,10.10.1.22:8080,10.10.1.23:8080,10.10.1.24:8080,10.10.1.25:8080,10.10.1.26:8080,10.10.1.27:8080,10.10.1.28:8080,10.10.1.29:8080,10.10.1.30:8080"

    docker build -t loadbalancer:latest -f Dockerfile .
    docker rm -f lb 2>/dev/null || true
    docker run -d --name lb --restart=always \
        --network host \
        -e LB_PORT=8080 \
        -e LB_ALGORITHM="$ALGO" \
        -e LB_QRIF=0.84 \
        -e LB_SELECTION_CHOICES=2 \
        -e LB_PROBE_INTERVAL=1s \
        -e LB_USE_SERVER_RIF=false \
        -e BACKENDS="$BACKENDS" \
        loadbalancer:latest
    ;;

  backend)
    # extra_arg is the CPU load level (0..400).
    CPU_LOAD="$EXTRA"
    docker build -t backend:latest -f backend/Dockerfile ./backend
    docker rm -f backend 2>/dev/null || true
    docker run -d --name backend --restart=always \
        --network host \
        --cpus 1 \
        -e PORT=8080 \
        -e SERVER_ID="$(hostname)" \
        -e CPU_LOAD="$CPU_LOAD" \
        backend:latest
    ;;

  loadgen)
    if ! command -v hey >/dev/null 2>&1; then
        HEY_URL=$(curl -fsSL https://api.github.com/repos/rakyll/hey/releases/latest \
                  | jq -r '.assets[] | select(.name == "hey_linux_amd64") | .browser_download_url')
        curl -fsSL "$HEY_URL" -o /usr/local/bin/hey
        chmod +x /usr/local/bin/hey
    fi
    # Rendi eseguibili tutti gli script dell'esperimento
    chmod +x "$WORKDIR"/*.sh
    ;;

  *)
    echo "Unknown role: $ROLE"
    exit 1
    ;;
esac

echo "==> Setup complete for role=$ROLE"
date
