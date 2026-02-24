#!/bin/bash
#
# analyze-parallel.sh - Optimized Parallel analysis with budget caps
#

set -euo pipefail

# 1. Path Configuration (Home directory to fix Hostinger /tmp issues)
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

# 3. Framework Definitions with TARGETED TOKEN LIMITS
# These caps prevent Kimi/Gemini from writing "essays" that drain your budget.
declare -A FRAMEWORKS=(
    ["01-phase"]="600"
    ["02-metrics"]="800"
    ["03-ai-moat"]="800"
    ["04-strategic-moat"]="900"
    ["05-sentiment"]="700"
    ["06-growth"]="800"
    ["07-business"]="800"
    ["08-risk"]="700"
)

# 4. Initialize
init_trace
mkdir -p "$OUTPUTS_DIR" "$CACHE_DIR"
[ "$LIVE" != "--live" ] && { echo "DRY RUN: $TICKER_UPPER"; exit 0; }

echo "🚀 Phase 1: Running 8 frameworks in parallel (Budget Capped)..."

# Launch workers
PIDS=()
for fw_id in "${!FRAMEWORKS[@]}"; do
    LIMIT="${FRAMEWORKS[$fw_id]}"
    PROMPT_FILE="$PROMPTS_DIR/$fw_id.txt"
    
    # Pass LIMIT as the 5th argument to run-framework.sh
    "$SCRIPT_DIR/run-framework.sh" "$TICKER_UPPER" "$fw_id" "$PROMPT_FILE" "$OUTPUTS_DIR" "$LIMIT" &
    PIDS+=($!)
done

# Wait for all background jobs
for pid in "${PIDS[@]}"; do wait $pid; done

# ============================================
# Phase 2: The "Synthesis Diet" (Optimized)
# ============================================
echo "🧪 Phase 2: Generating Lean Synthesis..."

SYNTH_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_synthesis.md"
# We only take the first 400 words of each framework to keep Synthesis input cost low.
COMBINED_CONTEXT=""
for fw_id in "${!FRAMEWORKS[@]}"; do
    FW_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
    if [ -f "$FW_FILE" ]; then
        SUMMARY=$(head -n 50 "$FW_FILE") # Only ingest the top of each report
        COMBINED_CONTEXT="${COMBINED_CONTEXT}\n\n### Framework: $fw_id\n$SUMMARY"
    fi
done

# Call API for final synthesis with a 1200 token cap for the final report
SYNTH_PROMPT="You are the Lead Investment Committee Director. Based on these 8 framework summaries for $TICKER_UPPER, provide a final Buy/Hold/Sell verdict.
Context: $COMBINED_CONTEXT"

API_RESPONSE=$(call_llm_api "$SYNTH_PROMPT" "1200")
extract_content "$API_RESPONSE" > "$SYNTH_FILE"

# ============================================
# Performance & Delivery
# ============================================
echo "✅ Analysis Complete for $TICKER_UPPER"
cost_summary

# Telegram Delivery Logic...
# (Your existing send_telegram_chunked logic here)