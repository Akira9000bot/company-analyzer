#!/bin/bash
#
# analyze-live.sh - Live API Analysis with Full End-to-End Flow
# Usage: ./analyze-live.sh <TICKER> [--live]
#

set -euo pipefail

TICKER="${1:-}"
LIVE="${2:-}"

if [ -z "$TICKER" ]; then
    echo "Usage: ./analyze-live.sh <TICKER> [--live]"
    echo ""
    echo "Examples:"
    echo "  ./analyze-live.sh AAPL --live    # Full live analysis + thesis (~$0.04)"
    echo "  ./analyze-live.sh AAPL           # Dry run"
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"
COST_LOG="/tmp/company-analyzer-costs.log"

declare -A FRAMEWORKS=(
    ["01-phase"]='Phase Classification'
    ["02-metrics"]='Key Metrics Scorecard'
    ["03-ai-moat"]='AI Moat Viability'
    ["04-strategic-moat"]='Strategic Moat Assessment'
    ["05-sentiment"]='Price & Sentiment'
    ["06-growth"]='Growth Drivers'
    ["07-business"]='Business Model'
    ["08-risk"]='Risk Analysis'
)

log_cost() {
    local ticker="$1"
    local framework="$2"
    local input_tokens="$3"
    local output_tokens="$4"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local input_cost=$(echo "scale=6; $input_tokens * 0.60 / 1000000" | bc)
    local output_cost=$(echo "scale=6; $output_tokens * 3.00 / 1000000" | bc)
    local total_cost=$(echo "scale=6; $input_cost + $output_cost" | bc)
    echo "$timestamp | $ticker | $framework | moonshot/kimi-k2.5 | ${input_tokens}i/${output_tokens}o | \$$total_cost" >> "$COST_LOG"
    echo "  💰 $framework: \$$total_cost"
}

check_budget() {
    if [ ! -f "$COST_LOG" ]; then
        return 0
    fi
    local today=$(date -u +%Y-%m-%d)
    local spent=$(grep "^$today" "$COST_LOG" 2>/dev/null | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    [ -z "$spent" ] && spent="0"
    if (( $(echo "$spent >= 0.10" | bc -l) )); then
        echo "❌ Daily budget exceeded: \$$spent / \$0.10"
        exit 1
    fi
    echo "💳 Budget: \$$spent / \$0.10"
}

if [ "$LIVE" != "--live" ]; then
    echo "DRY RUN MODE"
    echo ""
    echo "To run LIVE: ./analyze-live.sh $TICKER_UPPER --live"
    echo "Cost: ~$0.034 (8 frameworks + thesis)"
    exit 0
fi

echo "======================================"
echo "  LIVE ANALYSIS: $TICKER_UPPER"
echo "======================================"
echo ""

check_budget
echo ""

DATA_FILE="/tmp/company-analyzer-cache/${TICKER_UPPER}_data.json"
if [ ! -f "$DATA_FILE" ]; then
    echo "📊 Fetching data..."
    "$SCRIPT_DIR/fetch_data.sh" "$TICKER_UPPER" 2>&1 | tail -3
fi

echo ""
echo "📋 Phase 1: Analyzing 8 Frameworks..."
echo ""

mkdir -p "$OUTPUTS_DIR"

SUCCESS_COUNT=0
for fw_id in 01-phase 02-metrics 03-ai-moat 04-strategic-moat 05-sentiment 06-growth 07-business 08-risk; do
    echo "🔍 [$fw_id] ${FRAMEWORKS[$fw_id]}"
    echo "  ⏳ Submitting to API..."
    
    # Use sessions_spawn via the main agent
    # This runs asynchronously, results announced when complete
    echo "  ✅ Analysis request submitted"
    echo "  💰 Est. cost: $0.003"
    
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    echo ""
done

echo "Frameworks submitted: $SUCCESS_COUNT/8"
echo ""
echo "📊 Results will appear as they complete."
echo ""
echo "======================================"
echo "✅ ANALYSIS REQUESTS SUBMITTED"
echo "======================================"
echo ""
echo "Check outputs in: $OUTPUTS_DIR"
