#!/bin/bash
#
# analyze-live.sh - Live API Analysis with Full End-to-End Flow
# Usage: ./analyze-live.sh <TICKER> [--live] [--telegram <CHAT_ID>]
#

set -euo pipefail

TICKER="${1:-}"
LIVE="${2:-}"
TELEGRAM_FLAG="${3:-}"
TELEGRAM_CHAT_ID="${4:-}"

if [ -z "$TICKER" ]; then
    echo "Usage: ./analyze-live.sh <TICKER> [--live] [--telegram <CHAT_ID>]"
    echo ""
    echo "Examples:"
    echo "  ./analyze-live.sh AAPL --live                      # Full live analysis"
    echo "  ./analyze-live.sh AAPL --live --telegram 123456    # With Telegram delivery"
    echo "  ./analyze-live.sh AAPL                             # Dry run"
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"
COST_LOG="/tmp/company-analyzer-costs.log"
CACHE_ID=""

# Telegram config
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

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

# ============================================
# ARCHITECTURE UPDATE 3: Telegram Delivery Loop
# ============================================
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
        # Extract chunk of max_length characters
        local chunk="${message:$offset:$max_length}"
        
        # Escape special characters for JSON
        local escaped_chunk=$(echo "$chunk" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
        
        # Send chunk
        local response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\":\"$chat_id\",\"text\":\"$escaped_chunk\",\"parse_mode\":\"Markdown\"}")
        
        if echo "$response" | grep -q '"ok":true'; then
            echo "    ✅ Chunk $chunk_num sent"
        else
            echo "    ❌ Chunk $chunk_num failed: $response"
            return 1
        fi
        
        offset=$((offset + max_length))
        chunk_num=$((chunk_num + 1))
        
        # Small delay to avoid rate limits
        sleep 0.5
    done
    
    echo "  ✅ Telegram delivery complete ($((chunk_num - 1)) chunks)"
}

# ============================================
# ARCHITECTURE UPDATE 1: Create Shared Cache
# ============================================
create_shared_cache() {
    local ticker_data="$1"
    
    echo "📦 Creating shared context cache..."
    
    # Create cache object with 10-minute TTL
    local cache_res=$(curl -s -X POST "https://api.moonshot.ai/v1/caching" \
        -H "Authorization: Bearer $MOONSHOT_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"kimi-k2.5\",
            \"messages\": [
                {
                    \"role\": \"system\",
                    \"content\": \"You are a financial analyst. Company data: $ticker_data\"
                }
            ],
            \"ttl\": 600
        }")
    
    CACHE_ID=$(echo "$cache_res" | jq -r '.id // empty')
    
    if [ -z "$CACHE_ID" ] || [ "$CACHE_ID" == "null" ]; then
        echo "  ⚠️  Cache creation failed, falling back to direct calls"
        CACHE_ID=""
        return 1
    fi
    
    echo "  ✅ Cache established: ${CACHE_ID:0:20}..."
    return 0
}

# Run framework analysis with shared cache
run_framework() {
    local fw_id="$1"
    local ticker="$2"
    local framework_prompt=$(cat "$PROMPTS_DIR/$fw_id.txt" 2>/dev/null || echo "Analyze $fw_id")
    
    local response
    if [ -n "$CACHE_ID" ]; then
        # Use cached context
        response=$(curl -s -X POST "https://api.moonshot.ai/v1/chat/completions" \
            -H "Authorization: Bearer $MOONSHOT_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"kimi-k2.5\",
                \"cache_id\": \"$CACHE_ID\",
                \"messages\": [
                    {\"role\": \"user\", \"content\": \"$framework_prompt\"}
                ]
            }")
    else
        # Fallback: include full context
        local full_prompt="Company: $ticker

$framework_prompt"
        response=$(curl -s -X POST "https://api.moonshot.ai/v1/chat/completions" \
            -H "Authorization: Bearer $MOONSHOT_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"kimi-k2.5\",
                \"messages\": [
                    {\"role\": \"user\", \"content\": \"$full_prompt\"}
                ]
            }")
    fi
    
    # Extract content and usage
    local content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    local input_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // 0')
    local output_tokens=$(echo "$response" | jq -r '.usage.completion_tokens // 0')
    
    # Save output
    echo "$content" > "$OUTPUTS_DIR/${ticker}_${fw_id}.md"
    
    # Log cost
    log_cost "$ticker" "$fw_id" "$input_tokens" "$output_tokens"
    
    echo "$content"
}

# ============================================
# ARCHITECTURE UPDATE 1 & 2: Synthesis with Cache and Screener Logic
# ============================================
run_synthesis() {
    local ticker="$1"
    
    echo ""
    echo "🧠 Phase 2: Strategic Synthesis (Binary Narrative Flip Detection)..."
    echo ""
    
    # Collect all 8 framework outputs
    local all_outputs=""
    for fw_id in 01-phase 02-metrics 03-ai-moat 04-strategic-moat 05-sentiment 06-growth 07-business 08-risk; do
        local fw_file="$OUTPUTS_DIR/${ticker}_${fw_id}.md"
        if [ -f "$fw_file" ]; then
            all_outputs="${all_outputs}### ${FRAMEWORKS[$fw_id]} ###\n$(cat "$fw_file")\n\n"
        fi
    done
    
    # Read synthesis prompt
    local synthesis_prompt=$(cat "$PROMPTS_DIR/09-synthesis.txt" 2>/dev/null)
    if [ -z "$synthesis_prompt" ]; then
        # Fallback if file doesn't exist yet
        synthesis_prompt="You are a strategic investment screener. Analyze the following 8 framework outputs and provide:
1. BINARY NARRATIVE FLIP DETECTION: Identify if there's a potential 180-degree shift in the investment thesis (e.g., growth story turning to value trap, or vice versa)
2. SEAT-BASED SaaS PENALTY: Flag any heavy reliance on seat-based SaaS revenue models - these are structurally disadvantaged in AI era
3. FINAL VERDICT: BUY / HOLD / SELL with conviction level (High/Medium/Low)"
    fi
    
    local synthesis_message="$synthesis_prompt\n\n=== 8 FRAMEWORK ANALYSES ===\n\n$all_outputs"
    
    local response
    if [ -n "$CACHE_ID" ]; then
        # Use SAME cache_id as frameworks - no data resend
        response=$(curl -s -X POST "https://api.moonshot.ai/v1/chat/completions" \
            -H "Authorization: Bearer $MOONSHOT_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"kimi-k2.5\",
                \"cache_id\": \"$CACHE_ID\",
                \"messages\": [
                    {\"role\": \"user\", \"content\": \"$synthesis_message\"}
                ]
            }")
    else
        # Fallback
        response=$(curl -s -X POST "https://api.moonshot.ai/v1/chat/completions" \
            -H "Authorization: Bearer $MOONSHOT_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"kimi-k2.5\",
                \"messages\": [
                    {\"role\": \"user\", \"content\": \"$synthesis_message\"}
                ]
            }")
    fi
    
    local content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    local input_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // 0')
    local output_tokens=$(echo "$response" | jq -r '.usage.completion_tokens // 0')
    
    # Save synthesis
    echo "$content" > "$OUTPUTS_DIR/${ticker}_synthesis.md"
    log_cost "$ticker" "09-synthesis" "$input_tokens" "$output_tokens"
    
    echo "$content"
}

# ============================================
# MAIN EXECUTION
# ============================================

if [ "$LIVE" != "--live" ]; then
    echo "DRY RUN MODE"
    echo ""
    echo "To run LIVE: ./analyze-live.sh $TICKER_UPPER --live"
    echo "With Telegram: ./analyze-live.sh $TICKER_UPPER --live --telegram <CHAT_ID>"
    exit 0
fi

echo "======================================"
echo "  LIVE ANALYSIS: $TICKER_UPPER"
echo "======================================"
echo ""

check_budget
echo ""

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' is required"
    exit 1
fi

if [ -z "${MOONSHOT_API_KEY:-}" ]; then
    echo "❌ Error: MOONSHOT_API_KEY not set"
    exit 1
fi

# Prepare data
DATA_FILE="/tmp/company-analyzer-cache/${TICKER_UPPER}_data.json"
if [ ! -f "$DATA_FILE" ]; then
    echo "📊 Fetching data..."
    "$SCRIPT_DIR/fetch_data.sh" "$TICKER_UPPER" 2>&1 | tail -3
fi

TICKER_DATA=$(cat "$DATA_FILE" 2>/dev/null | jq -c . 2>/dev/null || echo "{\"ticker\":\"$TICKER_UPPER\"}")

mkdir -p "$OUTPUTS_DIR"

# Create shared cache for all frameworks + synthesis
create_shared_cache "$TICKER_DATA"

echo ""
echo "📋 Phase 1: Analyzing 8 Frameworks (Parallel)..."
echo ""

# Run 8 frameworks in parallel
for fw_id in 01-phase 02-metrics 03-ai-moat 04-strategic-moat 05-sentiment 06-growth 07-business 08-risk; do
    (
        run_framework "$fw_id" "$TICKER_UPPER" > /dev/null 2>&1
    ) &
done

# Wait for all frameworks
wait
echo "  ✅ All 8 frameworks complete"

# Run synthesis using same cache
SYNTHESIS_OUTPUT=$(run_synthesis "$TICKER_UPPER")

# Display synthesis
echo ""
echo "======================================"
echo "  SYNTHESIS & VERDICT"
echo "======================================"
echo ""
echo "$SYNTHESIS_OUTPUT"
echo ""

# ============================================
# ARCHITECTURE UPDATE 3: Safe Telegram Delivery
# ============================================
if [ "$TELEGRAM_FLAG" == "--telegram" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    echo "======================================"
    echo "  DELIVERING TO TELEGRAM"
    echo "======================================"
    echo ""
    
    # Build full message
    FULL_MESSAGE="📊 *${TICKER_UPPER} Analysis*

${SYNTHESIS_OUTPUT}

*8 Frameworks Analyzed* ✅"
    
    send_telegram_chunked "$FULL_MESSAGE" "$TELEGRAM_CHAT_ID"
fi

echo "======================================"
echo "✅ ANALYSIS COMPLETE"
echo "======================================"
echo ""
echo "Outputs saved: $OUTPUTS_DIR/${TICKER_UPPER}_*.md"
