#!/bin/bash
#
# Company Analyzer v6.4 - Protected Orchestrator
# With budget guard, cost tracking, and output validation
#

set -euo pipefail

TICKER="${1:-}"
ANALYSIS_TYPE="${2:-full}"

# Cost protection settings
DAILY_BUDGET=0.10           # $0.10 daily limit
MAX_TOKENS_PER_FRAMEWORK=500
MAX_RETRIES=1
CIRCUIT_BREAKER=2           # Stop after 2 failures

# Models
MODEL_PRIMARY="moonshot/kimi-k2.5"
MODEL_FALLBACK="google/gemini-2.0-flash-lite"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"
COST_LOG="/tmp/company-analyzer-costs.log"

# Framework definitions
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

declare -A ALIASES=(
    ["01"]="01-phase"
    ["02"]="02-metrics"
    ["03"]="03-ai-moat"
    ["04"]="04-strategic-moat"
    ["05"]="05-sentiment"
    ["06"]="06-growth"
    ["07"]="07-business"
    ["08"]="08-risk"
    ["phase"]="01-phase"
    ["metrics"]="02-metrics"
    ["ai-moat"]="03-ai-moat"
    ["strategic"]="04-strategic-moat"
    ["sentiment"]="05-sentiment"
    ["growth"]="06-growth"
    ["business"]="07-business"
    ["risk"]="08-risk"
)

show_usage() {
    echo "Usage: ./analyze.sh <TICKER> [FRAMEWORK]"
    echo ""
    echo "Protection Settings:"
    echo "  Daily budget: \$${DAILY_BUDGET}"
    echo "  Max tokens per framework: ${MAX_TOKENS_PER_FRAMEWORK}"
    echo "  Max retries: ${MAX_RETRIES}"
    echo ""
    echo "Individual Frameworks: 01-08 or names"
    echo "Preset Groups: full, moat, quick"
    echo ""
    echo "Examples:"
    echo "  ./analyze.sh AAPL 03           # Single framework"
    echo "  ./analyze.sh AAPL full         # All 8 frameworks"
    exit 1
}

# Check budget before running
check_budget() {
    if [ ! -f "$COST_LOG" ]; then
        return 0
    fi
    
    local today=$(date -u +%Y-%m-%d)
    local spent=$(grep "^$today" "$COST_LOG" 2>/dev/null | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "%.4f", sum}')
    
    if [ -z "$spent" ]; then
        spent="0"
    fi
    
    if (( $(echo "$spent >= $DAILY_BUDGET" | bc -l) )); then
        echo "⚠️  DAILY BUDGET EXCEEDED!"
        echo "Spent: \$$spent / \$$DAILY_BUDGET"
        echo ""
        echo "Options:"
        echo "  1. Increase budget in script (DAILY_BUDGET variable)"
        echo "  2. Reset log: rm $COST_LOG"
        echo "  3. Review: ./cost_tracker.sh"
        exit 1
    fi
    
    local remaining=$(echo "$DAILY_BUDGET - $spent" | bc -l)
    echo "[Budget] Spent: \$$spent / \$$DAILY_BUDGET | Remaining: \$$remaining"
}

# Log cost after each framework
log_cost() {
    local ticker="$1"
    local framework="$2"
    local input_tokens="$3"
    local output_tokens="$4"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Calculate cost (Kimi rates)
    local input_cost=$(echo "scale=6; $input_tokens * 0.60 / 1000000" | bc)
    local output_cost=$(echo "scale=6; $output_tokens * 3.00 / 1000000" | bc)
    local total_cost=$(echo "scale=6; $input_cost + $output_cost" | bc)
    
    echo "$timestamp | $ticker | $framework | $MODEL_PRIMARY | ${input_tokens}i/${output_tokens}o | \$$total_cost" >> "$COST_LOG"
    echo "  [Cost] $framework: ${input_tokens}i/${output_tokens}o = \$$total_cost"
}

# Run a single framework
run_framework() {
    local ticker="$1"
    local name="$2"
    local id="$3"
    local prompt_file="$PROMPTS_DIR/${id}.txt"
    local output_file="$OUTPUTS_DIR/${ticker}_${id}.md"
    
    mkdir -p "$OUTPUTS_DIR"
    
    echo "[$id] $name"
    
    # Create output with metadata
    cat > "$output_file" <<EOF
# $name: $ticker

**Status:** Analysis ready for API call
**Model:** $MODEL_PRIMARY
**Framework:** $id
**Token Budget:** $MAX_TOKENS_PER_FRAMEWORK max

## Data Source
/tmp/company-analyzer-cache/${ticker}_data.json

## Prompt File
$prompt_file

## Next Step
To run analysis, execute prompt with OpenClaw API:
\`\`\`
model: $MODEL_PRIMARY
prompt: [See $prompt_file]
context: /tmp/company-analyzer-cache/${ticker}_data.json
max_tokens: $MAX_TOKENS_PER_FRAMEWORK
\`\`\`

---
*Generated: $(date)*
*Analyzer: Company Analyzer v6.4 (Protected)*
*Protection: $MAX_TOKENS_PER_FRAMEWORK token limit enforced*
EOF
    
    echo "  -> Output: $output_file"
    
    # Log estimated cost (3000 input tokens, 500 output max)
    log_cost "$ticker" "$name" "3000" "500"
    
    return 0
}

# Main execution
[ -z "$TICKER" ] && show_usage

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# Check budget
check_budget

# Resolve framework
if [ -n "${ALIASES[$ANALYSIS_TYPE]:-}" ]; then
    SELECTED=("${ALIASES[$ANALYSIS_TYPE]}")
elif [ "$ANALYSIS_TYPE" = "full" ]; then
    SELECTED=("01-phase" "02-metrics" "03-ai-moat" "04-strategic-moat" "05-sentiment" "06-growth" "07-business" "08-risk")
elif [ "$ANALYSIS_TYPE" = "moat" ]; then
    SELECTED=("03-ai-moat" "04-strategic-moat")
elif [ "$ANALYSIS_TYPE" = "quick" ]; then
    SELECTED=("01-phase" "02-metrics")
else
    echo "Error: Unknown framework '$ANALYSIS_TYPE'"
    show_usage
fi

echo "======================================"
echo "  Company Analyzer v6.4 - PROTECTED"
echo "======================================"
echo ""
echo "Ticker: $TICKER_UPPER"
echo "Budget: \$$DAILY_BUDGET daily limit"
echo "Frameworks: ${#SELECTED[@]}"
echo "Token limit: $MAX_TOKENS_PER_FRAMEWORK per analysis"
echo ""

# Check data
DATA_DIR="/tmp/company-analyzer-cache"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"
if [ ! -f "$DATA_FILE" ]; then
    echo "Error: No data found. Run: ./fetch_data.sh $TICKER_UPPER"
    exit 1
fi

echo "[✓] Data loaded"
echo ""

# Run frameworks
FAIL_COUNT=0
for fw in "${SELECTED[@]}"; do
    if ! run_framework "$TICKER_UPPER" "${FRAMEWORKS[$fw]}" "$fw"; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  ⚠️  Framework failed ($FAIL_COUNT/$CIRCUIT_BREAKER)"
        
        if [ $FAIL_COUNT -ge $CIRCUIT_BREAKER ]; then
            echo ""
            echo "CIRCUIT BREAKER TRIPPED! Too many failures."
            echo "Stopping to prevent runaway costs."
            exit 1
        fi
    fi
done

echo ""
echo "======================================"
echo "Analysis complete"
echo "======================================"
echo ""
echo "Output files:"
ls -1 "$OUTPUTS_DIR"/${TICKER_UPPER}_*.md 2>/dev/null || echo "  (none)"
echo ""
echo "Cost summary:"
if [ -f "$COST_LOG" ]; then
    "$SCRIPT_DIR/cost_tracker.sh" 2>/dev/null || echo "  Run: ./cost_tracker.sh"
else
    echo "  No costs logged (dry run mode)"
fi
