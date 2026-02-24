#!/bin/bash
# run-framework.sh - Momentum-Aware Context Hand-off
# Updated to support enriched JSON and sequential inference.

set -euo pipefail

# 1. Environment Setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/cache.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh"
source "$SCRIPT_DIR/lib/api-client.sh"
source "$SCRIPT_DIR/lib/trace.sh"

# 2. Argument Parsing & Defaults
TICKER="${1:-}"
FW_ID="${2:-}"
PROMPT_FILE="${3:-}"
OUTPUT_DIR="${4:-$SKILL_DIR/assets/outputs}"
LIMIT_ARG="${5:-}"

# Inherit context from analyze-pipeline.sh
PREVIOUS_CONTEXT="${SUMMARY_CONTEXT:-None}"

# Max Token Guardrails
declare -A MAX_TOKENS=(
    ["01-phase"]=1000 ["02-metrics"]=1200 ["03-ai-moat"]=1200 
    ["04-strategic-moat"]=1200 ["05-sentiment"]=1000 ["06-growth"]=1200 
    ["07-business"]=1200 ["08-risk"]=1200
)

FW_MAX_TOKENS="${LIMIT_ARG:-${MAX_TOKENS[$FW_ID]:-800}}"

# 3. Data Segmenting (Surgical Injection)
TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
DATA_FILE="$SKILL_DIR/.cache/data/${TICKER_UPPER}_data.json"

get_relevant_context() {
    if [ ! -f "$DATA_FILE" ]; then echo "{}"; return; fi
    case "$FW_ID" in
        "07-business")
            # Inject profile and financial metrics for business evaluation
            jq -c '{profile: .company_profile, metrics: .financial_metrics, valuation: .valuation}' "$DATA_FILE" ;;
        "03-ai-moat") 
            # Inject ROE, PEG, and Earnings Surprises for Moat inference
            jq -c '{momentum: .momentum, valuation: .valuation, description: .company_profile.description}' "$DATA_FILE" ;;
        "08-risk") 
            # Inject valuation and momentum for Risk analysis
            jq -c '{valuation: .valuation, momentum: .momentum, profile: .company_profile}' "$DATA_FILE" ;;
        "01-phase"|"02-metrics") 
            # Core financial metrics
            jq -c '{metrics: .financial_metrics, valuation: .valuation}' "$DATA_FILE" ;;
        *) 
            # Default to description and basic profile
            jq -c '{profile: .company_profile, valuation: .valuation}' "$DATA_FILE" ;;
    esac
}

# 4. Initialization & Cache Check
init_trace
mkdir -p "$OUTPUT_DIR"
CONTEXT=$(get_relevant_context)
PROMPT_CONTENT=$(cat "$PROMPT_FILE")

# The Context Bridge: Combine the raw data + previous framework results
FULL_PROMPT="Company: $TICKER_UPPER
Analysis Context from Previous Steps: $PREVIOUS_CONTEXT

Raw Data:
$CONTEXT

Task Instructions:
$PROMPT_CONTENT"

CACHE_KEY=$(cache_key "$TICKER_UPPER" "$FW_ID" "$FULL_PROMPT")

# 5. Cache & Budget Enforcement
# CACHED_RESPONSE=$(cache_get "$CACHE_KEY" || echo "")
# if [ -n "$CACHED_RESPONSE" ]; then
#     echo "$CACHED_RESPONSE" > "$OUTPUT_DIR/${TICKER_UPPER}_${FW_ID}.md"
#     log_trace "INFO" "$FW_ID" "Cache HIT"
#     exit 0
# fi

if ! check_budget "$FW_ID"; then
    log_trace "ERROR" "$FW_ID" "Budget check failed"
    exit 1
fi

# 6. API Execution (Gemini 3 Flash)
API_RESPONSE=$(call_llm_api "$FULL_PROMPT" "$FW_MAX_TOKENS")
CONTENT=$(extract_content "$API_RESPONSE")
read INPUT_TOKENS OUTPUT_TOKENS <<< $(extract_usage "$API_RESPONSE")

# 7. Final Save & Metadata
echo "$CONTENT" > "$OUTPUT_DIR/${TICKER_UPPER}_${FW_ID}.md"
log_cost "$TICKER_UPPER" "$FW_ID" "$INPUT_TOKENS" "$OUTPUT_TOKENS"
log_trace "INFO" "$FW_ID" "Complete | ${INPUT_TOKENS}i/${OUTPUT_TOKENS}o"

METADATA=$(jq -n --arg i "$INPUT_TOKENS" --arg o "$OUTPUT_TOKENS" '{input: $i, output: $o}')
cache_set "$CACHE_KEY" "$CONTENT" "$METADATA"

echo "✅ $FW_ID complete"