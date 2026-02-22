#!/bin/bash
#
# lib/cost-tracker.sh - Cost tracking and budget management
#

COST_LOG="/tmp/company-analyzer-costs.log"
DAILY_BUDGET=0.10

# Initialize cost log
init_cost_tracker() {
    touch "$COST_LOG"
}

# Check if running within budget
# Returns: 0 if OK, 1 if budget exceeded
# Usage: check_budget [framework_name]
check_budget() {
    local framework="${1:-}"
    local today=$(date -u +%Y-%m-%d)
    
    init_cost_tracker
    
    # Calculate today's spend
    local spent=$(grep "^${today}T" "$COST_LOG" 2>/dev/null | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    [ -z "$spent" ] && spent="0"
    
    # Check if budget exceeded
    if (( $(echo "$spent >= $DAILY_BUDGET" | bc -l) )); then
        echo "❌ Daily budget exceeded: \$$spent / \$$DAILY_BUDGET"
        if [ -n "$framework" ]; then
            echo "   Cannot run framework: $framework"
        fi
        return 1
    fi
    
    local remaining=$(echo "scale=4; $DAILY_BUDGET - $spent" | bc)
    echo "💳 Budget: \$$spent / \$$DAILY_BUDGET (remaining: \$$remaining)"
    
    if [ -n "$framework" ]; then
        echo "   Framework: $framework"
    fi
    
    return 0
}

# Log API call cost
# Usage: log_cost <ticker> <framework> <input_tokens> <output_tokens>
log_cost() {
    local ticker="$1"
    local framework="$2"
    local input_tokens="$3"
    local output_tokens="$4"
    
    init_cost_tracker
    
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local input_cost=$(echo "scale=6; $input_tokens * 0.60 / 1000000" | bc)
    local output_cost=$(echo "scale=6; $output_tokens * 3.00 / 1000000" | bc)
    local total_cost=$(echo "scale=6; $input_cost + $output_cost" | bc)
    
    echo "$timestamp | $ticker | $framework | moonshot/kimi-k2.5 | ${input_tokens}i/${output_tokens}o | \$$total_cost" >> "$COST_LOG"
    echo "  💰 $framework: \$$total_cost (${input_tokens}i/${output_tokens}o tokens)"
}

# Get daily spend amount
# Usage: get_daily_spend [date]
# Returns: amount spent (e.g., "0.0423")
get_daily_spend() {
    local date_str="${1:-$(date -u +%Y-%m-%d)}"
    
    if [ ! -f "$COST_LOG" ]; then
        echo "0"
        return 0
    fi
    
    local spent=$(grep "^${date_str}T" "$COST_LOG" 2>/dev/null | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    [ -z "$spent" ] && spent="0"
    
    echo "$spent"
}

# Get cost summary
# Usage: cost_summary
cost_summary() {
    if [ ! -f "$COST_LOG" ]; then
        echo "No cost data logged yet"
        return 0
    fi
    
    local today=$(date -u +%Y-%m-%d)
    local today_spent=$(get_daily_spend "$today")
    local total_spent=$(grep -oE '\$[0-9.]+' "$COST_LOG" 2>/dev/null | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    
    echo "Cost Summary:"
    echo "  Today: \$$today_spent / \$$DAILY_BUDGET"
    echo "  Total (all time): \$$total_spent"
    echo "  Log file: $COST_LOG"
}

# Show detailed cost history
# Usage: cost_history [limit]
cost_history() {
    local limit="${1:-50}"
    
    if [ ! -f "$COST_LOG" ]; then
        echo "No cost data logged yet"
        return 0
    fi
    
    echo "=== Cost History (last $limit entries) ==="
    tail -n "$limit" "$COST_LOG"
    echo ""
    echo "=== Total Spent ==="
    grep -oE '\$[0-9.]+' "$COST_LOG" | sed 's/\$//' | awk '{sum+=$1} END {printf "\$%.4f\n", sum}'
}

# Estimate cost for tokens
# Usage: estimate_cost <input_tokens> <output_tokens>
estimate_cost() {
    local input_tokens="$1"
    local output_tokens="$2"
    
    local input_cost=$(echo "scale=6; $input_tokens * 0.60 / 1000000" | bc)
    local output_cost=$(echo "scale=6; $output_tokens * 3.00 / 1000000" | bc)
    local total_cost=$(echo "scale=6; $input_cost + $output_cost" | bc)
    
    echo "Cost estimate for $input_tokens input / $output_tokens output tokens:"
    echo "  Input:  \$$input_cost"
    echo "  Output: \$$output_cost"
    echo "  Total:  \$$total_cost"
}

# Export functions if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f init_cost_tracker check_budget log_cost get_daily_spend cost_summary cost_history estimate_cost
fi
