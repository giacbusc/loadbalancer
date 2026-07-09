#!/bin/bash
# watch-backends.sh — Live table of the load on all backends.
#
# Queries /health on all 10 servers in parallel and shows
# cpu_load, active burners, p50 latency, RIF and health status.
# Great for verifying that dynamic-antagonist.sh is working
# BEFORE launching the experiment.
#
# USAGE:
#   ./watch-backends.sh              # refresh every 4s (default)
#   WATCH_INTERVAL=2 ./watch-backends.sh   # faster refresh
#
# TYPICAL WORKFLOW (two terminals on loadgen-0):
#   [terminal 1]  ./dynamic-antagonist.sh
#   [terminal 2]  ./watch-backends.sh
#   ... visually check that the loads change every 10s ...
#   [terminal 1]  Ctrl+C
#   [terminal 1]  ./run-experiment.sh 60 dynamic

INTERVAL="${WATCH_INTERVAL:-4}"
PORT=8080

# Servers: IP and label (H=heavy, M=medium, C=clean — original role)
declare -a IPS=(
    "10.10.1.21" "10.10.1.22" "10.10.1.23" "10.10.1.24"
    "10.10.1.25" "10.10.1.26" "10.10.1.27"
    "10.10.1.28" "10.10.1.29" "10.10.1.30"
)
declare -a LABELS=(
    "server-0(H)" "server-1(H)" "server-2(H)" "server-3(H)"
    "server-4(M)" "server-5(M)" "server-6(M)"
    "server-7(C)" "server-8(C)" "server-9(C)"
)

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

row_color() {
    local load="$1"
    if [[ "$load" == "?" ]]; then  printf '%s' "$DIM"
    elif (( load >= 300 ));        then printf '%s' "$RED"
    elif (( load >= 150 ));        then printf '%s' "$YELLOW"
    elif (( load  > 0   ));        then printf '%s' "$CYAN"
    else                                printf '%s' "$GREEN"
    fi
}

load_label() {
    local load="$1"
    if   [[ "$load" == "?" ]];   then echo "OFFLINE"
    elif (( load >= 300 ));      then echo "HEAVY  "
    elif (( load >= 150 ));      then echo "MEDIUM "
    elif (( load  > 0   ));      then echo "LIGHT  "
    else                              echo "CLEAN  "
    fi
}

# ---------------------------------------------------------------------------
# Temporary directory for curl responses (automatically cleaned up on exit)
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Fetch all backends in parallel
# ---------------------------------------------------------------------------
fetch_all() {
    local pids=()
    for i in "${!IPS[@]}"; do
        curl -fsS --max-time 3 \
             "http://${IPS[$i]}:${PORT}/health" \
             > "$TMP_DIR/$i.json" 2>/dev/null &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Find the most recent antagonist log
# ---------------------------------------------------------------------------
latest_antag_log() {
    ls -t /tmp/antagonist-*.log 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
while true; do
    fetch_all

    clear

    # ── Header ──────────────────────────────────────────────────────────────
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    printf "${BOLD}  BACKEND MONITOR  —  %s  —  refresh ogni %ss${RESET}\n" \
           "$(date '+%H:%M:%S')" "$INTERVAL"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    # ── Columns ─────────────────────────────────────────────────────────────
    printf "${BOLD}  %-14s  %5s  %-8s  %4s  %9s  %5s${RESET}\n" \
           "SERVER" "LOAD" "STATO" "BRN" "p50 (ms)" "RIF"
    echo -e "  ─────────────────────────────────────────────────────"

    # ── Backend rows ────────────────────────────────────────────────────────
    for i in "${!IPS[@]}"; do
        label="${LABELS[$i]}"
        jf="$TMP_DIR/$i.json"

        if [[ -s "$jf" ]]; then
            cpu_load=$(jq -r '.cpu_load // 0'  "$jf" 2>/dev/null || echo "0")
            rif=$(     jq -r '.rif      // 0'  "$jf" 2>/dev/null || echo "0")
            p50_us=$(  jq -r '.p50_us   // 0'  "$jf" 2>/dev/null || echo "0")

            # Convert microseconds → milliseconds with one decimal digit
            p50_ms=$(awk -v us="$p50_us" 'BEGIN{printf "%.1f", us/1000}')
            burners=$(( cpu_load / 50 ))
            state_lbl=$(load_label "$cpu_load")
            col=$(row_color "$cpu_load")

            printf "${col}  %-14s  %5d  %-8s  %4d  %9s  %5d${RESET}\n" \
                   "$label" "$cpu_load" "$state_lbl" "$burners" "${p50_ms}ms" "$rif"
        else
            printf "${DIM}  %-14s  %5s  %-8s  %4s  %9s  %5s${RESET}\n" \
                   "$label" "?" "OFFLINE" "?" "?" "?"
        fi

        # Visual separator between the three groups (H/M/C)
        if [[ $i -eq 3 ]] || [[ $i -eq 6 ]]; then
            echo -e "  ─────────────────────────────────────────────────────"
        fi
    done

    echo -e "  ─────────────────────────────────────────────────────"

    # ── Color legend ────────────────────────────────────────────────────────
    echo -e "  ${RED}■ HEAVY ≥300${RESET}  ${YELLOW}■ MEDIUM ≥150${RESET}  ${CYAN}■ LIGHT >0${RESET}  ${GREEN}■ CLEAN =0${RESET}"

    # ── Latest antagonist event ─────────────────────────────────────────────
    echo ""
    antag_log=$(latest_antag_log)
    if [[ -n "$antag_log" ]]; then
        last_event=$(grep "Stato" "$antag_log" 2>/dev/null | tail -1)
        next_event=$(grep "Stato" "$antag_log" 2>/dev/null | tail -2 | head -1)
        if [[ -n "$last_event" ]]; then
            echo -e "  ${BOLD}Antagonista:${RESET} ${last_event}"
        else
            echo -e "  ${DIM}Antagonista: log trovato ma ancora nessun stato applicato${RESET}"
        fi
        echo -e "  ${DIM}Log: $antag_log${RESET}"
    else
        echo -e "  ${DIM}Antagonista: non attivo (lancia ./dynamic-antagonist.sh &)${RESET}"
    fi

    echo ""
    echo -e "  ${DIM}Ctrl+C per uscire${RESET}"

    sleep "$INTERVAL"
done
