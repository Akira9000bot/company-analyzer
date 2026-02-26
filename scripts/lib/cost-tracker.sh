#!/bin/bash
# lib/cost-tracker.sh - Dynamic Cost Tracking

# Get paths
COST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COST_SKILL_DIR="$(cd "$COST_LIB_DIR/../.." && pwd)"
PRICES_FILE="$COST_LIB_DIR/prices.json"
CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
COST_LOG="$COST_SKILL_DIR/.cache/costs.log"
DAILY_BUDGET=0.10

init_cost_tracker() {
    mkdir -p "$(dirname "$COST_LOG")"
    touch "$COST_LOG"
}

# NEW: Unified Budget Check Function
# Returns 0 if under budget, 1 if over budget.
check_budget() {
    [ ! -f "$COST_LOG" ] && return 0
    
    local today=$(date -u +%Y-%m-%d)
    local spent=$(grep "^${today}T" "$COST_LOG" 2>/dev/null | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    [ -z "$spent" ] && spent="0"
    
    if (( $(echo "$spent >= $DAILY_BUDGET" | bc -l) )); then
        echo "⚠️ BUDGET EXCEEDED: \$$spent / \$$DAILY_BUDGET" >&2
        return 1
    fi
    return 0
}

# Log API call cost with Dynamic Price Lookup
# Usage: log_cost <ticker> <framework> <input_tokens> <output_tokens>
log_cost() {
    local ticker="$1"
    local framework="$2"
    local INPUT_TOKENS="$3"
    local OUTPUT_TOKENS="$4"
    
    init_cost_tracker

    # 1. Determine active model with safe fallback
    local active_model="google/gemini-3-flash-preview"
    if [ -f "$CONFIG_FILE" ]; then
        active_model=$(jq -r '.agents.defaults.model.primary // "google/gemini-3-flash-preview"' "$CONFIG_FILE" 2>/dev/null || echo "google/gemini-3-flash-preview")
    fi

    # 2. Lookup prices for that specific model with safe fallbacks
    local in_rate="0.50"
    local out_rate="3.00"
    if [ -f "$PRICES_FILE" ]; then
        in_rate=$(jq -r ".\"$active_model\".input // 0.50" "$PRICES_FILE" 2>/dev/null || echo "0.50")
        out_rate=$(jq -r ".\"$active_model\".output // 3.00" "$PRICES_FILE" 2>/dev/null || echo "3.00")
    fi

    # 3. Calculate (Scale 6 for high precision on pennies)
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local input_cost=$(echo "scale=6; $INPUT_TOKENS * $in_rate / 1000000" | bc)
    local output_cost=$(echo "scale=6; $OUTPUT_TOKENS * $out_rate / 1000000" | bc)
    local total_cost=$(echo "scale=6; $input_cost + $output_cost" | bc)
    
    # 4. Save to log
    echo "$timestamp | $ticker | $framework | $active_model | ${INPUT_TOKENS}i/${OUTPUT_TOKENS}o | \$$total_cost" >> "$COST_LOG"
    echo "  💰 $framework: \$$total_cost (Model: $active_model)"
}

# Usage: cost_summary
cost_summary() {
    [ ! -f "$COST_LOG" ] && { echo "No data."; return 0; }
    
    local today=$(date -u +%Y-%m-%d)
    local spent=$(grep "^${today}T" "$COST_LOG" | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    [ -z "$spent" ] && spent="0"
    
    echo "--- DAILY BUDGET TRACKER ---"
    echo "  Today: \$$spent / \$$DAILY_BUDGET"
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f init_cost_tracker log_cost cost_summary check_budget
fi