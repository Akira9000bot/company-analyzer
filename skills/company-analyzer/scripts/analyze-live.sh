#!/bin/bash
#
# analyze-live.sh - Live API Analysis with Full End-to-End Flow
# Usage: ./analyze-live.sh <TICKER> [--live]
#
# Runs all 8 frameworks via API calls + generates investment thesis
#

set -euo pipefail

TICKER="${1:-}"
LIVE="${2:-}"

if [ -z "$TICKER" ]; then
    echo "Usage: ./analyze-live.sh <TICKER> [--live]"
    echo ""
    echo "Examples:"
    echo "  ./analyze-live.sh AAPL --live    # Full live analysis + thesis (~$0.04)"
    echo "  ./analyze-live.sh AAPL           # Dry run (show what would run)"
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"
COST_LOG="/tmp/company-analyzer-costs.log"

# Framework mapping
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

# Cost tracking
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

# Check budget
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

# Run single framework via API
run_framework_live() {
    local ticker="$1"
    local fw_id="$2"
    local fw_name="${FRAMEWORKS[$fw_id]}"
    local prompt_file="$PROMPTS_DIR/${fw_id}.txt"
    local output_file="$OUTPUTS_DIR/${ticker}_${fw_id}.md"
    local data_file="/tmp/company-analyzer-cache/${ticker}_data.json"
    
    echo "🔍 [$fw_id] $fw_name"
    
    # Read prompt and data
    local prompt_content=$(cat "$prompt_file")
    local data_content=$(cat "$data_file" 2>/dev/null || echo "{}")
    
    # Create full prompt with context
    local full_prompt="ANALYZE THIS COMPANY:\n\nDATA:\n$data_content\n\n\n$prompt_content"
    
    # Call API via sessions_spawn
    local result=$(sessions_spawn "Analyze $ticker using the $fw_name framework. \n\n$full_prompt\n\nProvide concise analysis within 500 tokens." 2>&1 || echo "API_CALL_FAILED")
    
    # Check if API call succeeded
    if echo "$result" | grep -q "API_CALL_FAILED\|FailoverError\|429"; then
        echo "  ⚠️  API call failed for $fw_id"
        return 1
    fi
    
    # Save result
    cat > "$output_file" <<EOF
# $fw_name: $ticker

**Status:** Live Analysis Complete
**Model:** moonshot/kimi-k2.5
**Framework:** $fw_id
**Generated:** $(date)

---

$result

---
*Live analysis via Company Analyzer*
EOF
    
    # Log cost (estimate ~3000 input, ~500 output tokens)
    log_cost "$ticker" "$fw_name" "3000" "500"
    
    echo "  ✅ Complete: $output_file"
    return 0
}

# Generate synthesis
generate_thesis() {
    local ticker="$1"
    local synthesis_input="$OUTPUTS_DIR/${ticker}_synthesis_input.txt"
    local output_file="$OUTPUTS_DIR/${ticker}_SYNTHESIS_live.md"
    
    echo ""
    echo "🧠 Generating Investment Thesis..."
    
    # Build synthesis input from all frameworks
    {
        echo "# Synthesis Input: $ticker"
        echo ""
        echo "## All 8 Framework Summaries"
        echo ""
        for fw_id in 01-phase 02-metrics 03-ai-moat 04-strategic-moat 05-sentiment 06-growth 07-business 08-risk; do
            local fw_file="$OUTPUTS_DIR/${ticker}_${fw_id}.md"
            if [ -f "$fw_file" ]; then
                echo "### ${FRAMEWORKS[$fw_id]}"
                tail -n +15 "$fw_file" | head -30
                echo ""
            fi
        done
        echo ""
        echo "## Instructions"
        echo "Generate investment thesis with:"
        echo "- Verdict: BUY / HOLD / SELL"
        echo "- Confidence: High/Medium/Low"
        echo "- Executive summary (3-4 sentences)"
        echo "- Bull case (3 points)"
        echo "- Bear case (2 points)"
        echo "- Key contradictions"
        echo "- Primary risk"
    } > "$synthesis_input"
    
    # Call API for synthesis
    local synthesis_prompt=$(cat "$synthesis_input")
    local thesis=$(sessions_spawn "As an investment analyst, synthesize these 8 framework analyses into a coherent investment thesis for $ticker.\n\n$synthesis_prompt\n\nBe concise. Maximum 600 tokens." 2>&1 || echo "THESIS_GENERATION_FAILED")
    
    if echo "$thesis" | grep -q "THESIS_GENERATION_FAILED\|FailoverError\|429"; then
        echo "  ⚠️  Thesis generation failed"
        return 1
    fi
    
    # Parse verdict
    local verdict=$(echo "$thesis" | grep -iE "verdict|recommendation|buy|hold|sell" | head -1 | grep -oE "BUY|HOLD|SELL" || echo "PENDING")
    
    cat > "$output_file" <<EOF
# Investment Thesis: $ticker

**Verdict:** $verdict
**Status:** Live Generated
**Model:** moonshot/kimi-k2.5
**Cost:** ~$0.01
**Generated:** $(date)

---

$thesis

---
*Live synthesis via Company Analyzer v6.5*
EOF
    
    log_cost "$ticker" "Synthesis" "3500" "600"
    
    echo "  ✅ Thesis: $output_file"
    echo "  📊 Verdict: $verdict"
    
    return 0
}

# Main
if [ "$LIVE" != "--live" ]; then
    echo "DRY RUN MODE"
    echo ""
    echo "To run LIVE analysis with API calls (~$0.04 total):"
    echo "  ./analyze-live.sh $TICKER_UPPER --live"
    echo ""
    echo "This will:"
    echo "  1. Run 8 frameworks via API (~$0.003 each)"
    echo "  2. Generate investment thesis (~$0.01)"
    echo "  3. Save all outputs to assets/outputs/"
    echo ""
    echo "Current budget:"
    check_budget
    exit 0
fi

echo "======================================"
echo "  LIVE ANALYSIS: $TICKER_UPPER"
echo "======================================"
echo ""

# Check budget
check_budget
echo ""

# Check data
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
    if run_framework_live "$TICKER_UPPER" "$fw_id"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
    echo ""
done

echo "Frameworks completed: $SUCCESS_COUNT/8"
echo ""

# Generate thesis if we have results
if [ $SUCCESS_COUNT -ge 4 ]; then
    generate_thesis "$TICKER_UPPER"
else
    echo "⚠️  Too few frameworks succeeded. Skipping thesis."
fi

echo ""
echo "======================================"
echo "✅ LIVE ANALYSIS COMPLETE"
echo "======================================"
echo ""
echo "📁 Output files:"
ls -1 "$OUTPUTS_DIR"/${TICKER_UPPER}_*.md 2>/dev/null | while read f; do
    echo "   • $(basename "$f")"
done
echo ""
echo "💰 Total cost:"
grep "^$(date -u +%Y-%m-%d).*${TICKER_UPPER}" "$COST_LOG" 2>/dev/null | grep -oE '\$[0-9.]+' | sed 's/\$//' | awk '{sum+=$1} END {printf "\$%.4f\n", sum}' || echo "  See: ./cost_tracker.sh"
echo ""
