#!/bin/bash
#
# Budget Guard - Prevent runaway spending
#

DAILY_BUDGET="${1:-0.10}"
LOG_FILE="/tmp/company-analyzer-costs.log"

check_budget() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "0"
        return
    fi
    
    local today=$(date -u +%Y-%m-%d)
    local today_costs=$(grep "^$today" "$LOG_FILE" 2>/dev/null | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    
    if [ -z "$today_costs" ] || [ "$today_costs" = "0" ]; then
        today_costs="0"
    fi
    
    echo "$today_costs"
}

current_spend=$(check_budget)

echo "Budget Guard"
echo "Daily budget: \$$DAILY_BUDGET"
echo "Spent today: \$$current_spend"

if (( $(echo "$current_spend >= $DAILY_BUDGET" | bc -l) )); then
    echo ""
    echo "⚠️  BUDGET EXCEEDED!"
    echo "Spent: \$$current_spend / \$$DAILY_BUDGET"
    exit 1
else
    remaining=$(echo "$DAILY_BUDGET - $current_spend" | bc -l)
    echo "Remaining: \$$remaining"
    echo "Status: ✅ Within budget"
    exit 0
fi
