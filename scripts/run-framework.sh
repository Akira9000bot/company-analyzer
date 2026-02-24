#!/bin/bash
# run-framework.sh - Final Merge: Budget Safety + Data Efficiency

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
LIMIT_ARG="${5:-}" # Passed from analyze-parallel.sh

# Fallback internal map if $5 is empty
declare -A MAX_TOKENS=(
    ["01-phase"]=600 ["02-metrics"]=800 ["03-ai-moat"]=800 
    ["04-strategic-moat"]=900 ["05-sentiment"]=700 ["06-growth"]=800 
    ["07-business"]=800 ["08-risk"]=700
)
FW_MAX_TOKENS="${LIMIT_ARG:-${MAX_TOKENS[$FW_ID]:-800}}"

# 3. Data Segmenting (THE BIG COST SAVER)
TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
DATA_FILE="$SKILL_DIR/.cache/data/${TICKER_UPPER}_data.json"

get_relevant_context() {
    if [ ! -f "$DATA_FILE" ]; then echo "{}"; return; fi
    case "$FW_ID" in
        "07-business"|"03-ai-moat") jq -r '.sec_data.item1 // .full_text[:15000]' "$DATA_FILE" ;;
        "08-risk") jq -r '.sec_data.item1a // .full_text[:15000]' "$DATA_FILE" ;;
        "01-phase"|"02-metrics") jq -c '.financial_metrics' "$DATA_FILE" ;;
        *) jq -r '.full_text[:10000]' "$DATA_FILE" ;;
    esac
}

# 4. Initialization & Cache Check
init_trace
mkdir -p "$OUTPUT_DIR"
CONTEXT=$(get_relevant_context)
PROMPT_CONTENT=$(cat "$PROMPT_FILE")
FULL_PROMPT="Company: $TICKER_UPPER\n\nData: $CONTEXT\n\nInstructions: $PROMPT_CONTENT"
CACHE_KEY=$(cache_key "$TICKER_UPPER" "$FW_ID" "$FULL_PROMPT")

CACHED_RESPONSE=$(cache_get "$CACHE_KEY")
if [ -n "$CACHED_RESPONSE" ]; then
    echo "$CACHED_RESPONSE" > "$OUTPUT_DIR/${TICKER_UPPER}_${FW_ID}.md"
    log_trace "INFO" "$FW_ID" "Cache HIT | Age: $(cache_age "$CACHE_KEY")d"
    exit 0
fi

# 5. API Execution with Budget Guard
if ! check_budget "$FW_ID"; then
    log_trace "ERROR" "$FW_ID" "Budget check failed"
    exit 1
fi

API_RESPONSE=$(call_llm_api "$FULL_PROMPT" "$FW_MAX_TOKENS")
CONTENT=$(extract_content "$API_RESPONSE")
read INPUT_TOKENS OUTPUT_TOKENS <<< $(extract_usage "$API_RESPONSE")

# 6. Save & Log
echo "$CONTENT" > "$OUTPUT_DIR/${TICKER_UPPER}_${FW_ID}.md"
log_cost "$TICKER_UPPER" "$FW_ID" "$INPUT_TOKENS" "$OUTPUT_TOKENS"
log_trace "INFO" "$FW_ID" "Complete | ${INPUT_TOKENS}i/${OUTPUT_TOKENS}o"

# Save to cache with metadata (your production requirement)
METADATA=$(jq -n --arg i "$INPUT_TOKENS" --arg o "$OUTPUT_TOKENS" '{input: $i, output: $o}')
cache_set "$CACHE_KEY" "$CONTENT" "$METADATA"

echo "✅ $FW_ID complete"