#!/bin/bash
#
# Cost Tracker - Log all API usage
#

LOG_FILE="/tmp/company-analyzer-costs.log"

show_costs() {
    if [ -f "$LOG_FILE" ]; then
        echo "=== Cost History ==="
        cat "$LOG_FILE"
        echo ""
        echo "=== Total Spent ==="
        grep -oE '\$[0-9.]+' "$LOG_FILE" | sed 's/\$//' | awk '{sum+=$1} END {printf "\$%.4f\n", sum}'
    else
        echo "No cost data logged yet"
    fi
}

# If run directly, show costs
show_costs
