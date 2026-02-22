#!/bin/bash
#
# synthesize.sh - Generate final synthesis from framework outputs
# Usage: ./synthesize.sh <TICKER> [--live]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"

# Source libraries
source "$SCRIPT_DIR/lib/cache.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/cost-tracker.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/api-client.sh" 2>/dev/null || true

TICKER="${1:-}"
LIVE="${2:-}"

[ -z "$TICKER" ] && { echo "Usage: $0 <TICKER> [--live]"; exit 1; }

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

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

# Check if framework outputs exist
echo "Checking for framework outputs..."
MISSING=()
for fw_id in "${!FRAMEWORKS[@]}"; do
    FW_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
    if [ ! -f "$FW_FILE" ]; then
        MISSING+=("$fw_id")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "⚠️  Missing framework outputs: ${MISSING[*]}"
    echo "   Run: ./analyze-parallel.sh $TICKER_UPPER --live"
    exit 1
fi

echo "✅ All 8 framework outputs found"

# Dry run mode
if [ "$LIVE" != "--live" ]; then
    echo ""
    echo "DRY RUN MODE"
    echo ""
    echo "To generate synthesis: $0 $TICKER_UPPER --live"
    echo "Cost: ~$0.01"
    exit 0
fi

# Collect all framework outputs
echo ""
echo "🧠 Generating synthesis..."

ALL_OUTPUTS=""
for fw_id in 01-phase 02-metrics 03-ai-moat 04-strategic-moat 05-sentiment 06-growth 07-business 08-risk; do
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

# Call API for synthesis (use libraries if available)
if type call_moonshot_api &>/dev/null; then
    SYNTHESIS_RESPONSE=$(call_moonshot_api "$SYNTHESIS_MESSAGE")
    
    if [ $? -ne 0 ]; then
        echo "❌ Synthesis API call failed"
        exit 1
    fi
    
    SYNTHESIS_CONTENT=$(extract_content "$SYNTHESIS_RESPONSE")
    read SYNTH_INPUT SYNTH_OUTPUT <<< $(extract_usage "$SYNTHESIS_RESPONSE")
    log_cost "$TICKER_UPPER" "09-synthesis" "$SYNTH_INPUT" "$SYNTH_OUTPUT"
else
    # Fallback to direct curl
    echo "  (Using direct API call)"
    
    AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
    MOONSHOT_API_KEY=$(jq -r '.profiles["moonshot:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")
    
    if [ -z "$MOONSHOT_API_KEY" ]; then
        echo "❌ No API key found"
        exit 1
    fi
    
    json_payload=$(jq -n \
        --arg model "kimi-k2.5" \
        --arg content "$SYNTHESIS_MESSAGE" \
        '{model: $model, messages: [{role: "user", content: $content}]}')
    
    response=$(curl -s --max-time 60 -X POST "https://api.moonshot.ai/v1/chat/completions" \
        -H "Authorization: Bearer $MOONSHOT_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$json_payload")
    
    SYNTHESIS_CONTENT=$(echo "$response" | jq -r '.choices[0].message.content // empty')
fi

# Save synthesis
echo "$SYNTHESIS_CONTENT" > "$OUTPUTS_DIR/${TICKER_UPPER}_synthesis.md"

echo ""
echo "======================================"
echo "  SYNTHESIS COMPLETE"
echo "======================================"
echo ""
echo "$SYNTHESIS_CONTENT"
echo ""
echo "======================================"
echo "Saved to: $OUTPUTS_DIR/${TICKER_UPPER}_synthesis.md"
