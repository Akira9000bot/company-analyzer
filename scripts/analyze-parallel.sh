#!/bin/bash
#
# analyze-parallel.sh - Parallel company analysis with all 8 frameworks
# Usage: ./analyze-parallel.sh <TICKER> [--live] [--telegram <CHAT_ID>]
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"

# Source libraries
source "$SCRIPT_DIR/lib/cache.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh"
source "$SCRIPT_DIR/lib/api-client.sh"
source "$SCRIPT_DIR/lib/trace.sh"

# Parse arguments
TICKER="${1:-}"
LIVE="${2:-}"
TELEGRAM_FLAG="${3:-}"
TELEGRAM_CHAT_ID="${4:-}"

if [ -z "$TICKER" ]; then
    echo "Usage: $0 <TICKER> [--live] [--telegram <CHAT_ID>]"
    echo ""
    echo "Examples:"
    echo "  $0 AAPL --live                      # Full live analysis"
    echo "  $0 AAPL --live --telegram 123456    # With Telegram delivery"
    echo "  $0 AAPL                             # Dry run (no cost)"
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# Initialize trace
init_trace
log_trace "INFO" "MAIN" "=== Analysis Start: $TICKER_UPPER ==="
log_trace "INFO" "MAIN" "Mode: ${LIVE:-dry-run}"

# Telegram config
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

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

# Dry run mode
if [ "$LIVE" != "--live" ]; then
    echo "======================================"
    echo "  DRY RUN MODE: $TICKER_UPPER"
    echo "======================================"
    echo ""
    echo "This would run all 8 frameworks in parallel:"
    for fw_id in "${!FRAMEWORKS[@]}"; do
        echo "  - $fw_id: ${FRAMEWORKS[$fw_id]}"
    done
    echo ""
    echo "To run LIVE: $0 $TICKER_UPPER --live"
    echo "With Telegram: $0 $TICKER_UPPER --live --telegram <CHAT_ID>"
    exit 0
fi

echo "======================================"
echo "  LIVE ANALYSIS: $TICKER_UPPER"
echo "======================================"
echo ""

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' is required"
    exit 1
fi

if ! validate_api_key; then
    exit 1
fi

# Initialize
init_cache
init_cost_tracker
mkdir -p "$OUTPUTS_DIR"

# Check overall budget before starting
if ! check_budget; then
    exit 1
fi

echo ""

# Fetch data if not cached
DATA_FILE="$SKILL_DIR/.cache/data/${TICKER_UPPER}_data.json"
if [ ! -f "$DATA_FILE" ]; then
    echo "📊 Fetching company data..."
    "$SCRIPT_DIR/fetch_data.sh" "$TICKER_UPPER" 2>&1 | tail -5
    echo ""
fi

# Validate data
if [ ! -s "$DATA_FILE" ] || ! jq -e '.financial_metrics' "$DATA_FILE" > /dev/null; then
    echo "❌ Error: Required financial data is missing. Aborting analysis to save API credits."
    exit 1
fi

# Record start time for performance measurement
START_TIME=$(date +%s)
log_trace "INFO" "MAIN" "Starting parallel execution of 8 frameworks"

echo "🚀 Phase 1: Running 8 frameworks in parallel..."
echo ""

# Array to store background job PIDs
declare -a PIDS=()
declare -a FW_IDS=("01-phase" "02-metrics" "03-ai-moat" "04-strategic-moat" "05-sentiment" "06-growth" "07-business" "08-risk")

# Launch all frameworks in parallel
for fw_id in "${FW_IDS[@]}"; do
    PROMPT_FILE="$PROMPTS_DIR/$fw_id.txt"

    if [ ! -f "$PROMPT_FILE" ]; then
        echo "  ⚠️  Prompt file missing: $PROMPT_FILE"
        log_trace "WARN" "$fw_id" "Prompt file missing"
        continue
    fi

    # Run framework in background
    "$SCRIPT_DIR/run-framework.sh" "$TICKER_UPPER" "$fw_id" "$PROMPT_FILE" "$OUTPUTS_DIR" &
    PID=$!
    PIDS+=($PID)
    echo "  🔄 Launched $fw_id (PID: $PID)"
    log_trace "INFO" "$fw_id" "Launched (PID: $PID)"
done

echo ""
echo "⏳ Waiting for all frameworks to complete..."
echo ""

# Wait for all jobs and track failures
FAILED_FRAMEWORKS=()
SUCCESS_COUNT=0

for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    fw_id="${FW_IDS[$i]}"

    if wait $pid; then
        echo "  ✅ $fw_id complete"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ❌ $fw_id failed (exit code: $?)"
        FAILED_FRAMEWORKS+=("$fw_id")
    fi
done

END_TIME=$(date +%s)
FRAMEWORK_TIME=$((END_TIME - START_TIME))

log_trace "INFO" "MAIN" "Frameworks complete | Success: $SUCCESS_COUNT/8 | Time: ${FRAMEWORK_TIME}s"

echo ""
echo "📊 Parallel execution complete: $SUCCESS_COUNT/8 frameworks succeeded in ${FRAMEWORK_TIME}s"

# Check for failures
if [ ${#FAILED_FRAMEWORKS[@]} -gt 0 ]; then
    echo ""
    echo "⚠️  Failed frameworks: ${FAILED_FRAMEWORKS[*]}"

    # Circuit breaker: if 2+ frameworks fail, stop
    if [ ${#FAILED_FRAMEWORKS[@]} -ge 2 ]; then
        echo "❌ Circuit breaker: 2+ frameworks failed, stopping analysis"
        exit 1
    fi
fi

echo ""

# ============================================ 
# Phase 2: Synthesis 
# ============================================ 
echo "🧠 Phase 2: Strategic Synthesis..."
echo ""

log_trace "INFO" "SYNTH" "Starting synthesis phase"

# Check budget before synthesis 
if ! check_budget "09-synthesis"; then 
    echo "❌ Cannot run synthesis - budget exceeded" 
    log_trace "ERROR" "SYNTH" "Budget exceeded, cannot synthesize"
    exit 1 
fi

# Collect all framework outputs
ALL_OUTPUTS=""
for fw_id in "${FW_IDS[@]}"; do
    FW_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
    if [ -f "$FW_FILE" ]; then
        ALL_OUTPUTS="${ALL_OUTPUTS}### ${FRAMEWORKS[$fw_id]} ###
$(cat "$FW_FILE")

"
    fi
done

# Read synthesis prompt
SYNTHESIS_PROMPT=$(cat "$PROMPTS_DIR/09-synthesis.txt" 2>/dev/null)
if [ -z "$SYNTHESIS_PROMPT" ]; then
    SYNTHESIS_PROMPT="You are a strategic investment screener. Analyze the following 8 framework outputs and provide a BUY/HOLD/SELL verdict."
fi

SYNTHESIS_MESSAGE="$SYNTHESIS_PROMPT

=== 8 FRAMEWORK ANALYSES ===

$ALL_OUTPUTS"

# Call API for synthesis
SYNTH_START=$(date +%s)
SYNTHESIS_RESPONSE=$(call_moonshot_api "$SYNTHESIS_MESSAGE")

if [ $? -ne 0 ]; then
    echo "❌ Synthesis API call failed"
    exit 1
fi

SYNTHESIS_CONTENT=$(extract_content "$SYNTHESIS_RESPONSE")
read SYNTH_INPUT SYNTH_OUTPUT <<< $(extract_usage "$SYNTHESIS_RESPONSE")

# Save synthesis
echo "$SYNTHESIS_CONTENT" > "$OUTPUTS_DIR/${TICKER_UPPER}_synthesis.md"
log_cost "$TICKER_UPPER" "09-synthesis" "$SYNTH_INPUT" "$SYNTH_OUTPUT"

SYNTH_END=$(date +%s)
SYNTH_TIME=$((SYNTH_END - SYNTH_START))

echo "  ✅ Synthesis complete (${SYNTH_TIME}s)"
echo ""

# Calculate total time
TOTAL_TIME=$((END_TIME - START_TIME + SYNTH_TIME))

# ============================================
# Display Results
# ============================================
echo "======================================"
echo "  SYNTHESIS & VERDICT"
echo "======================================"
echo ""
echo "$SYNTHESIS_CONTENT"
echo ""

# Show cost summary
cost_summary
echo ""

# Show timing
echo "⏱️  Performance:"
echo "  Frameworks (parallel): ${FRAMEWORK_TIME}s"
echo "  Synthesis: ${SYNTH_TIME}s"
echo "  Total: ${TOTAL_TIME}s"
echo ""

# Estimate sequential time (approx 8x parallel time per framework)
EST_SEQUENTIAL_TIME=$((FRAMEWORK_TIME * 3))
TIME_SAVED=$((EST_SEQUENTIAL_TIME - FRAMEWORK_TIME))
echo "  Estimated sequential time: ~${EST_SEQUENTIAL_TIME}s"
echo "  Time saved with parallelization: ~${TIME_SAVED}s"
echo ""

# ============================================
# Telegram Delivery
# ============================================
if [ "$TELEGRAM_FLAG" == "--telegram" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    echo "======================================"
    echo "  DELIVERING TO TELEGRAM"
    echo "======================================"
    echo ""

    send_telegram_chunked() {
        local message="$1"
        local chat_id="$2"
        local max_length=4000
        local total_length=${#message}
        local offset=0
        local chunk_num=1

        if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
            echo "  ⚠️  TELEGRAM_BOT_TOKEN not set, skipping delivery"
            return 1
        fi

        echo "  📤 Delivering to Telegram (message length: $total_length)..."

        while [ $offset -lt $total_length ]; do
            local chunk="${message:$offset:$max_length}"
            local escaped_chunk=$(echo "$chunk" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')

            local response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -H "Content-Type: application/json" \
                -d "{\"chat_id\":\"$chat_id\",\"text\":\"$escaped_chunk\",\"parse_mode\":\"Markdown\"}" 2>/dev/null)

            if echo "$response" | grep -q '"ok":true'; then
                echo "    ✅ Chunk $chunk_num sent"
            else
                echo "    ❌ Chunk $chunk_num failed"
            fi

            offset=$((offset + max_length))
            chunk_num=$((chunk_num + 1))
            sleep 0.5
        done

        echo "  ✅ Telegram delivery complete ($((chunk_num - 1)) chunks)"
    }

    # Build full message
    FULL_MESSAGE="📊 *${TICKER_UPPER} Analysis (Parallel)*

${SYNTHESIS_CONTENT}

*8 Frameworks Analyzed* ✅
⏱️ Time: ${TOTAL_TIME}s | Parallel execution"

    send_telegram_chunked "$FULL_MESSAGE" "$TELEGRAM_CHAT_ID"
fi

log_trace "INFO" "MAIN" "=== Analysis Complete | Total Time: ${TOTAL_TIME}s ==="

echo "======================================"
echo "✅ ANALYSIS COMPLETE"
echo "======================================"
echo ""
echo "Trace log: assets/traces/${TICKER_UPPER}_$(date +%Y-%m-%d).trace"
echo "Outputs saved: $OUTPUTS_DIR/${TICKER_UPPER}_*.md"
echo ""
