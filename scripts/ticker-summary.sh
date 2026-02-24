#!/bin/bash
#
# ticker-summary.sh - Audit report for Ticker Analysis costs and efficiency
#

# 1. Path Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
COST_LOG="$SKILL_DIR/.cache/costs.log"

# Check if log exists
if [ ! -f "$COST_LOG" ]; then
    echo "❌ No cost log found at $COST_LOG"
    exit 1
fi

echo "========================================================="
echo "📊 COMPANY ANALYZER: TICKER COST SUMMARY"
echo "========================================================="
printf "%-10s | %-10s | %-12s | %-8s\n" "TICKER" "RUNS" "TOTAL TOKENS" "COST ($)"
echo "---------------------------------------------------------"

# 2. Process Log Data
# Aggregates Total Cost and Token Count per Ticker
awk -F' | ' '
{
    ticker = $4;
    # Extract tokens (format: 1234i/567o)
    split($10, t, "/");
    in_t = substr(t[1], 1, length(t[1])-1);
    out_t = substr(t[2], 1, length(t[2])-1);
    
    # Extract cost (format: $0.001234)
    cost_str = $12;
    gsub(/\$/, "", cost_str);
    
    # Accumulate
    counts[ticker]++;
    tokens[ticker] += (in_t + out_t);
    costs[ticker] += cost_str;
}
END {
    for (t in counts) {
        printf "%-10s | %-10d | %-12d | $%-8.4f\n", t, counts[t], tokens[t], costs[t]
    }
}' "$COST_LOG" | sort -rn -k 7

echo "---------------------------------------------------------"

# 3. Framework Efficiency Audit
echo ""
echo "🔍 Framework Efficiency (Average Cost per Call)"
echo "---------------------------------------------------------"
awk -F' | ' '
{
    fw = $6;
    cost_str = $12;
    gsub(/\$/, "", cost_str);
    
    fw_counts[fw]++;
    fw_costs[fw] += cost_str;
}
END {
    for (f in fw_counts) {
        avg = fw_costs[f] / fw_counts[f];
        printf "%-20s | Avg Cost: $%-8.6f | Runs: %d\n", f, avg, fw_counts[f]
    }
}' "$COST_LOG" | sort -rn -k 4

echo "========================================================="