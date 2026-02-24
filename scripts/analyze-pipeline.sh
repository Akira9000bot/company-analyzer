#!/bin/bash
#
# analyze-pipeline.sh - Sequential Analysis Pipeline with Context Hand-off
#

set -euo pipefail

# 1. Path Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"
CACHE_DIR="${HOME}/.openclaw/cache/company-analyzer"

# Source libraries
source "$SCRIPT_DIR/lib/cache.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh"
source "$SCRIPT_DIR/lib/api-client.sh"
source "$SCRIPT_DIR/lib/trace.sh"

# 2. Parse arguments
TICKER="${1:-}"
LIVE="${2:-}"
TELEGRAM_FLAG="${3:-}"
TELEGRAM_CHAT_ID="${4:-}"

[ -z "$TICKER" ] && { echo "Usage: $0 <TICKER> [--live]"; exit 1; }
TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# 3. Order-Specific Framework Sequence
# We run these in a specific logical order to build context.
FW_SEQUENCE=("01-phase" "02-metrics" "07-business" "03-ai-moat" "04-strategic-moat" "06-growth" "05-sentiment" "08-risk")

declare -A LIMITS=(
    ["01-phase"]="600" ["02-metrics"]="800" ["03-ai-moat"]="800"
    ["04-strategic-moat"]="900" ["05-sentiment"]="700" ["06-growth"]="800"
    ["07-business"]="800" ["08-risk"]="700"
)

# 4. Initialize
init_trace
init_cost_tracker
mkdir -p "$OUTPUTS_DIR" "$CACHE_DIR"

if [ "$LIVE" != "--live" ]; then
    echo "DRY RUN: $TICKER_UPPER Pipeline (8 steps)"
    exit 0
fi

# ============================================
# Phase 1: Sequential Execution
# ============================================
echo "🚀 Starting Sequential Analysis Pipeline for $TICKER_UPPER..."
echo "---------------------------------------------------------"

START_TIME=$(date +%s)
SUMMARY_CONTEXT=""

for fw_id in "${FW_SEQUENCE[@]}"; do
    LIMIT="${LIMITS[$fw_id]}"
    PROMPT_FILE="$PROMPTS_DIR/$fw_id.txt"
    
    echo "⏳ Step: $fw_id..."
    
    # We pass the SUMMARY_CONTEXT from previous runs as an environment variable 
    # if you want to modify run-framework.sh to use it.
    "$SCRIPT_DIR/run-framework.sh" "$TICKER_UPPER" "$fw_id" "$PROMPT_FILE" "$OUTPUTS_DIR" "$LIMIT"
    
    # Check for success
    if [ $? -ne 0 ]; then
        echo "❌ $fw_id failed. Aborting pipeline to save budget."
        exit 1
    fi
    
    # Extract the "Bottom Line" from this run for the next one (optional context hand-off)
    FW_OUT="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
    SUMMARY_LINE=$(head -n 5 "$FW_OUT" | tr '\n' ' ')
    SUMMARY_CONTEXT="${SUMMARY_CONTEXT}\n- $fw_id result: $SUMMARY_LINE"
    
    echo "  ✅ Done."
done

# ============================================
# Phase 2: High-Density Synthesis
# ============================================
echo "🧪 Generating Final Verdict..."
SYNTH_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_synthesis.md"
COMBINED_CONTEXT=""
for fw_id in "${FW_SEQUENCE[@]}"; do
    FW_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
    [ -f "$FW_FILE" ] && COMBINED_CONTEXT="${COMBINED_CONTEXT}\n\n### $fw_id\n$(head -n 20 "$FW_FILE")"
done

SYNTH_PROMPT="Act as Chief Investment Officer. Synthesize these 8 reports for $TICKER_UPPER into a Buy/Hold/Sell verdict. Focus on the tension between the AI Moat and the Execution Risks.
Reports: $COMBINED_CONTEXT"

API_RESPONSE=$(call_llm_api "$SYNTH_PROMPT" "1200")
extract_content "$API_RESPONSE" > "$SYNTH_FILE"

# ============================================
# Performance & Delivery
# ============================================
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo "---------------------------------------------------------"
echo "✅ Pipeline Complete for $TICKER_UPPER in ${TOTAL_TIME}s"
cost_summary

# Add Telegram logic here if desired (using the SYNTH_FILE)