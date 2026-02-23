#!/bin/bash
#
# run-framework.sh - Run a single framework with caching support
# Usage: ./run-framework.sh <ticker> <fw_id> <prompt_file> [output_dir]
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/cache.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh"
source "$SCRIPT_DIR/lib/api-client.sh"
source "$SCRIPT_DIR/lib/trace.sh"

# Parse arguments
TICKER="${1:-}"
FW_ID="${2:-}"
PROMPT_FILE="${3:-}"
OUTPUT_DIR="${4:-$(dirname "$SCRIPT_DIR")/assets/outputs}"

# Initialize trace after parsing args
init_trace
log_trace "INFO" "$FW_ID" "Framework execution starting"

if [ -z "$TICKER" ] || [ -z "$FW_ID" ] || [ -z "$PROMPT_FILE" ]; then
    echo "Usage: $0 <ticker> <fw_id> <prompt_file> [output_dir]"
    echo "Example: $0 AAPL 01-phase /path/to/01-phase.txt"
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# Validate inputs
if [ ! -f "$PROMPT_FILE" ]; then
    echo "❌ Prompt file not found: $PROMPT_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Read framework prompt
FRAMEWORK_PROMPT=$(cat "$PROMPT_FILE")

# Build full prompt with company context
FULL_PROMPT="Company: $TICKER_UPPER

$FRAMEWORK_PROMPT"

# Generate cache key
CACHE_KEY=$(cache_key "$TICKER_UPPER" "$FW_ID" "$FULL_PROMPT")

# Check cache first
echo "🔍 Checking cache for $FW_ID..."
log_trace "INFO" "$FW_ID" "Checking cache"
CACHED_RESPONSE=$(cache_get "$CACHE_KEY" 2>/dev/null) || true

if [ -n "$CACHED_RESPONSE" ]; then
    AGE_DAYS=$(cache_age "$CACHE_KEY")
    echo "✅ Cache HIT for $FW_ID (${AGE_DAYS} days old)"
    log_trace "INFO" "$FW_ID" "Cache HIT | Age: ${AGE_DAYS}d | Cost: $0.00"
    echo "$CACHED_RESPONSE" > "$OUTPUT_DIR/${TICKER_UPPER}_${FW_ID}.md"
    echo "💰 $FW_ID: $0.00 (cached)"
    exit 0
fi

echo "📝 Cache MISS for $FW_ID - calling API..."
log_trace "INFO" "$FW_ID" "Cache MISS - calling API"

# Check budget before API call
if ! check_budget "$FW_ID"; then
    echo "❌ Budget check failed for $FW_ID"
    exit 1
fi

# Call API with retry logic
API_RESPONSE=$(call_moonshot_api "$FULL_PROMPT")

if [ $? -ne 0 ]; then
    echo "❌ API call failed for $FW_ID"
    log_trace "ERROR" "$FW_ID" "API call failed after retries"
    exit 1
fi

# Extract content and usage
CONTENT=$(extract_content "$API_RESPONSE")
read INPUT_TOKENS OUTPUT_TOKENS <<< $(extract_usage "$API_RESPONSE")

# Save output
echo "$CONTENT" > "$OUTPUT_DIR/${TICKER_UPPER}_${FW_ID}.md"

# Log cost
log_cost "$TICKER_UPPER" "$FW_ID" "$INPUT_TOKENS" "$OUTPUT_TOKENS"
log_trace "INFO" "$FW_ID" "Complete | Tokens: ${INPUT_TOKENS}i/${OUTPUT_TOKENS}o"

# Cache the response (best effort - don't fail if caching breaks)
if [ -n "$INPUT_TOKENS" ] && [ -n "$OUTPUT_TOKENS" ]; then
    METADATA=$(jq -n --arg ticker "$TICKER_UPPER" --arg fw "$FW_ID" --argjson input "$INPUT_TOKENS" --argjson output "$OUTPUT_TOKENS" '{ticker: $ticker, framework: $fw, tokens: {input: $input, output: $output}}' 2>/dev/null) || METADATA="{}"
    cache_set "$CACHE_KEY" "$(cat "$OUTPUT_DIR/${TICKER_UPPER}_${FW_ID}.md")" "$METADATA" 2>/dev/null || log_trace "WARN" "$FW_ID" "Cache write failed"
fi

echo "✅ $FW_ID complete"
exit 0
