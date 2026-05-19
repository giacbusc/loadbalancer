#!/bin/bash
# parse-results.sh — extract a CSV summary from a results directory.
# Usage: ./parse-results.sh /tmp/results-XXXX

set -e
DIR="${1:?results dir required}"

OUT="$DIR/summary.csv"
echo "algorithm,level,qps,total_req,p50_us,p90_us,p95_us,p99_us,errors" > "$OUT"

for ALGO in prequal rr; do
    for f in "$DIR"/${ALGO}_*.txt; do
        [ -e "$f" ] || continue
        BASE=$(basename "$f" .txt)
        LEVEL=${BASE#${ALGO}_}

        QPS=$(grep "Requests/sec:" "$f" | awk '{print $2}' | head -1)
        TOTAL=$(grep -A 200 "Status code distribution" "$f" \
                | grep -E "^\s+\[[0-9]{3}\]" \
                | awk '{sum+=$2} END {print sum+0}')

        # Extract latency percentiles (hey's output uses lines like "  50% in 0.0xxx secs")
        P50=$(grep "50% in" "$f" | awk '{print $3}' | head -1)
        P90=$(grep "90% in" "$f" | awk '{print $3}' | head -1)
        P95=$(grep "95% in" "$f" | awk '{print $3}' | head -1)
        P99=$(grep "99% in" "$f" | awk '{print $3}' | head -1)

        # hey outputs in seconds — convert to µs.
        us() { echo "$1" | awk '{printf "%.0f", $1*1000000}'; }

        ERRORS=$(grep -A 100 "Status code distribution" "$f" \
                 | grep -E "^\s+\[5[0-9]{2}\]" \
                 | awk '{sum+=$2} END {print sum+0}')

        echo "$ALGO,$LEVEL,$QPS,$TOTAL,$(us $P50),$(us $P90),$(us $P95),$(us $P99),$ERRORS" >> "$OUT"
    done
done

echo "Summary written to: $OUT"
echo
column -t -s, "$OUT"
