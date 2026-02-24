#!/bin/bash
#
# analyze-pipeline.sh - Momentum-Aware Analysis Pipeline
# Optimized for Gemini 3 Flash and Enriched JSON datasets.
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

[ -z "$TICKER" ] && { echo "Usage: $0 <TICKER> [--live]"; exit 1; }
TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# 3. Refined Sequence: Metrics & Business run BEFORE Moat
FW_SEQUENCE=("01-phase" "02-metrics" "07-business" "03-ai-moat" "04-strategic-moat" "06-growth" "05-sentiment" "08-risk")

declare -A LIMITS=(
    ["01-phase"]="600" ["02-metrics"]="800" ["03-ai-moat"]="1200"
    ["04-strategic-moat"]="900" ["05-sentiment"]="700" ["06-growth"]="800"
    ["07-business"]="800" ["08-risk"]="1000"
)

# 4. Initialize
init_trace
init_cost_tracker
mkdir -p "$OUTPUTS_DIR" "$CACHE_DIR"

if [ "$LIVE" != "--live" ]; then
    echo "🔍 DRY RUN: $TICKER_UPPER Pipeline (8 steps)"
    echo "   Sequence: ${FW_SEQUENCE[*]}"
    exit 0
fi

# ============================================
# Phase 1: Sequential Execution
# ============================================
echo "🚀 Starting Momentum Pipeline for $TICKER_UPPER..."
echo "---------------------------------------------------------"

START_TIME=$(date +%s)
export SUMMARY_CONTEXT="" # Export so run-framework.sh can read it

for fw_id in "${FW_SEQUENCE[@]}"; do
    LIMIT="${LIMITS[$fw_id]}"
    PROMPT_FILE="$PROMPTS_DIR/$fw_id.txt"
    
    echo "⏳ Step: $fw_id..."
    
    # Execute framework
    "$SCRIPT_DIR/run-framework.sh" "$TICKER_UPPER" "$fw_id" "$PROMPT_FILE" "$OUTPUTS_DIR" "$LIMIT"
    
    if [ $? -ne 0 ]; then
        echo "❌ $fw_id failed. Aborting pipeline."
        exit 1
    fi
    
    # Update Context Hand-off
    # We grab the first 5 lines (usually the score/verdict) for the next model's prompt
    FW_OUT="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
    SUMMARY_LINE=$(head -n 5 "$FW_OUT" | tr '\n' ' ' | sed 's/[#*]//g')
    SUMMARY_CONTEXT="${SUMMARY_CONTEXT}\n- Previous Step ($fw_id): $SUMMARY_LINE"
    
    echo "  ✅ Done. Cooling down TPM window..."
    
    # MANDATORY: 15s Sleep to prevent TPM spikes with enriched momentum data
    sleep 15 
done

# ============================================
# Phase 2: Local Report Concatenation
# ============================================
echo "🧪 Compiling Final Research Dossier..."
SYNTH_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_FINAL_REPORT.md"

{
    echo "# Strategic Research Dossier: $TICKER_UPPER"
    echo "Analysis Date: $(date)"
    echo "Model: Gemini 3 Flash"
    echo "---"
    for fw_id in "${FW_SEQUENCE[@]}"; do
        FW_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
        if [ -f "$FW_FILE" ]; then
            HEADER=$(echo "$fw_id" | cut -d'-' -f2- | tr '[:lower:]' '[:upper:]')
            echo "## $HEADER"
            cat "$FW_FILE"
            echo -e "\n---\n"
        fi
    done
} > "$SYNTH_FILE"

echo "✅ Dossier saved to $SYNTH_FILE"