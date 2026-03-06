#!/bin/bash
#
# analyze.sh - Unified Company Analysis (LLM-powered via OpenClaw config)
# Usage: ./analyze.sh <TICKER> [--live]
#

set -euo pipefail

TICKER="${1:-}"
LIVE="${2:-}"

if [ -z "$TICKER" ]; then
    echo "Usage: ./analyze.sh <TICKER> [--live]"
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"
PROMPTS_DIR="$SKILL_DIR/references/prompts"

# Load shared libraries
source "$SCRIPT_DIR/lib/api-client.sh"
source "$SCRIPT_DIR/lib/cost-tracker.sh"
source "$SCRIPT_DIR/lib/trace.sh"

if [ "$LIVE" != "--live" ]; then
    echo "DRY RUN MODE: ./analyze.sh $TICKER_UPPER --live to execute"
    exit 0
fi

echo "======================================"
echo "  LIVE ANALYSIS: $TICKER_UPPER"
echo "======================================"

mkdir -p "$OUTPUTS_DIR"
init_trace

# 1. Fetch Data (same path as pipeline; fail if fetch does not produce file)
DATA_FILE="$SKILL_DIR/.cache/data/${TICKER_UPPER}_data.json"
if [ ! -f "$DATA_FILE" ]; then
    echo "📊 Fetching data..."
    "$SCRIPT_DIR/fetch_data.sh" "$TICKER_UPPER" || { echo "ERROR: fetch_data.sh failed for $TICKER_UPPER" >&2; exit 1; }
fi
[ ! -f "$DATA_FILE" ] && { echo "ERROR: No data file after fetch: $DATA_FILE" >&2; exit 1; }

# 2. Run 8 Frameworks (same order as analyze-pipeline.sh for consistent context hand-off)
FW_SEQUENCE=(01-phase 02-metrics 07-business 03-ai-moat 04-strategic-moat 06-growth 05-sentiment 08-risk)
echo "📋 Phase 1: Analyzing 8 Frameworks..."
ROLLING_CONTEXT_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_rolling_context.txt"
rm -f "$ROLLING_CONTEXT_FILE"

export SUMMARY_CONTEXT="None"

for fw_id in "${FW_SEQUENCE[@]}"; do
    echo -n "  🔄 $fw_id... "
    "$SCRIPT_DIR/run-framework.sh" "$TICKER_UPPER" "$fw_id" "$PROMPTS_DIR/$fw_id.txt" "$OUTPUTS_DIR" > /dev/null
    
    # Update SUMMARY_CONTEXT for next framework (Tail -n 3 to keep it small)
    if [ -f "$ROLLING_CONTEXT_FILE" ]; then
        SUMMARY_CONTEXT=$(tail -n 3 "$ROLLING_CONTEXT_FILE")
        export SUMMARY_CONTEXT
    fi
    echo "✅"
done

# 3. Strategic Synthesis
echo ""
echo "🧠 Phase 2: Strategic Synthesis..."

# Aggregate all framework outputs (same order as execution; use real newlines so LLM sees structured prompt)
ALL_OUTPUTS=""
for fw_id in "${FW_SEQUENCE[@]}"; do
    FW_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
    if [ -f "$FW_FILE" ]; then
        ALL_OUTPUTS="${ALL_OUTPUTS}
### $fw_id ###
$(cat "$FW_FILE")

"
    fi
done

SYNTH_FILE_PROMPT="$PROMPTS_DIR/09-synthesis.txt"
[ ! -f "$SYNTH_FILE_PROMPT" ] && { echo "ERROR: Synthesis prompt not found: $SYNTH_FILE_PROMPT" >&2; exit 1; }
SYNTHESIS_PROMPT=$(cat "$SYNTH_FILE_PROMPT")
# Inject numeric framework weights from config so synthesis can weigh evidence (adjust references/framework-weights.json to change)
WEIGHTS_FILE="$(dirname "$PROMPTS_DIR")/framework-weights.json"
if [ -f "$WEIGHTS_FILE" ]; then
    WEIGHTS_LINE=$(jq -r 'to_entries | map("\(.key)=\(.value * 100 | floor)%") | join(", ")' "$WEIGHTS_FILE" 2>/dev/null || true)
    [ -n "$WEIGHTS_LINE" ] && SYNTHESIS_PROMPT="$SYNTHESIS_PROMPT

NUMERIC FRAMEWORK WEIGHTS (total 100% of verdict influence; use when combining evidence and resolving conflicts): $WEIGHTS_LINE"
fi
# Inject reference date so synthesis uses current time for catalysts (avoids "Q4 2024" when we are in 2026)
REFERENCE_DATE=$(date -u +%Y-%m-%d)
REFERENCE_DATE_LINE="REFERENCE DATE: $REFERENCE_DATE. All VERDICT TRIGGERS (catalysts) must be expressed relative to this date—i.e. the next 2 quarters and upcoming earnings from today, not past quarters. Example: if today is March 2026, say 'Q1 2026' or 'upcoming Q1 2026 earnings,' not 'Q4 2024.'"

# Inject valuation anchors from data so synthesis uses current guidance/high target, not a lagging mean target
PRICE_LINE=""
if [ -f "$DATA_FILE" ]; then
    CURRENT_PRICE=$(jq -r '.valuation.current_price // empty' "$DATA_FILE" 2>/dev/null)
    TARGET_MEAN=$(jq -r '.valuation.analyst_mean_target // .valuation.target_mean_price // empty' "$DATA_FILE" 2>/dev/null)
    TARGET_HIGH=$(jq -r '.valuation.analyst_high_target // .valuation.target_high_price // empty' "$DATA_FILE" 2>/dev/null)
    INTERNAL_GUIDANCE_TARGET=$(jq -r '.valuation.internal_guidance_target // empty' "$DATA_FILE" 2>/dev/null)
    VALUATION_CONTEXT=$(jq -r '.valuation.valuation_context // empty' "$DATA_FILE" 2>/dev/null)
    GUIDANCE_EPS=$(jq -r '.valuation.guidance_eps // empty' "$DATA_FILE" 2>/dev/null)
    GUIDANCE_MULTIPLE=$(jq -r '.valuation.guidance_growth_multiple // empty' "$DATA_FILE" 2>/dev/null)
    GUIDANCE_FORWARD_PE=$(jq -r '.valuation.guidance_forward_pe // empty' "$DATA_FILE" 2>/dev/null)
    INST_OWNERSHIP=$(jq -r '.valuation.institutional_ownership_pct // empty' "$DATA_FILE" 2>/dev/null)
    INST_COUNT=$(jq -r '.valuation.institutions_count // empty' "$DATA_FILE" 2>/dev/null)
    PRIMARY_ANCHOR=$(jq -r '.valuation.primary_valuation_anchor // empty' "$DATA_FILE" 2>/dev/null)
    PRIMARY_ANCHOR_SOURCE=$(jq -r '.valuation.primary_valuation_anchor_source // empty' "$DATA_FILE" 2>/dev/null)
    if [ -n "$CURRENT_PRICE" ] && [ "$CURRENT_PRICE" != "null" ]; then
        PRICE_FMT=$(printf "%.2f" "$CURRENT_PRICE" 2>/dev/null || echo "$CURRENT_PRICE")
        PRICE_LINE="REFERENCE: Current price (from data): \$${PRICE_FMT}."
        if [ -n "$TARGET_MEAN" ] && [ "$TARGET_MEAN" != "null" ] && [ "$TARGET_MEAN" != "N/A" ]; then
            TARGET_FMT=$(printf "%.2f" "$TARGET_MEAN" 2>/dev/null || echo "$TARGET_MEAN")
            PRICE_LINE="$PRICE_LINE Analyst mean target (lagging consensus): \$${TARGET_FMT}."
        fi
        if [ -n "$TARGET_HIGH" ] && [ "$TARGET_HIGH" != "null" ] && [ "$TARGET_HIGH" != "N/A" ]; then
            TARGET_HIGH_FMT=$(printf "%.2f" "$TARGET_HIGH" 2>/dev/null || echo "$TARGET_HIGH")
            PRICE_LINE="$PRICE_LINE Analyst high target (primary anchor): \$${TARGET_HIGH_FMT}."
        fi
        if [ -n "$INTERNAL_GUIDANCE_TARGET" ] && [ "$INTERNAL_GUIDANCE_TARGET" != "null" ] && [ "$INTERNAL_GUIDANCE_TARGET" != "N/A" ]; then
            INTERNAL_FMT=$(printf "%.2f" "$INTERNAL_GUIDANCE_TARGET" 2>/dev/null || echo "$INTERNAL_GUIDANCE_TARGET")
            PRICE_LINE="$PRICE_LINE Internal guidance target (primary anchor): \$${INTERNAL_FMT}"
            if [ -n "$GUIDANCE_EPS" ] && [ "$GUIDANCE_EPS" != "null" ] && [ "$GUIDANCE_EPS" != "N/A" ] && [ -n "$GUIDANCE_MULTIPLE" ] && [ "$GUIDANCE_MULTIPLE" != "null" ] && [ "$GUIDANCE_MULTIPLE" != "N/A" ]; then
                PRICE_LINE="$PRICE_LINE from guidance EPS ${GUIDANCE_EPS} x ${GUIDANCE_MULTIPLE}x."
            else
                PRICE_LINE="$PRICE_LINE."
            fi
        fi
        if [ -n "$PRIMARY_ANCHOR" ] && [ "$PRIMARY_ANCHOR" != "null" ] && [ "$PRIMARY_ANCHOR" != "N/A" ] && [ -n "$PRIMARY_ANCHOR_SOURCE" ] && [ "$PRIMARY_ANCHOR_SOURCE" != "null" ] && [ "$PRIMARY_ANCHOR_SOURCE" != "N/A" ]; then
            PRIMARY_FMT=$(printf "%.2f" "$PRIMARY_ANCHOR" 2>/dev/null || echo "$PRIMARY_ANCHOR")
            PRICE_LINE="$PRICE_LINE Strongest primary valuation anchor: \$${PRIMARY_FMT} (${PRIMARY_ANCHOR_SOURCE})."
        fi
        if [ -n "$VALUATION_CONTEXT" ] && [ "$VALUATION_CONTEXT" != "null" ]; then
            PRICE_LINE="$PRICE_LINE Valuation context: ${VALUATION_CONTEXT}."
        fi
        if [ -n "$GUIDANCE_FORWARD_PE" ] && [ "$GUIDANCE_FORWARD_PE" != "null" ] && [ "$GUIDANCE_FORWARD_PE" != "N/A" ]; then
            PRICE_LINE="$PRICE_LINE Guidance-based forward P/E: ${GUIDANCE_FORWARD_PE}x."
        fi
        if [ -n "$INST_OWNERSHIP" ] && [ "$INST_OWNERSHIP" != "null" ] && [ "$INST_OWNERSHIP" != "N/A" ]; then
            PRICE_LINE="$PRICE_LINE Institutional ownership: ${INST_OWNERSHIP}"
            if [ -n "$INST_COUNT" ] && [ "$INST_COUNT" != "null" ] && [ "$INST_COUNT" != "N/A" ]; then
                PRICE_LINE="$PRICE_LINE across ${INST_COUNT} institutions."
            else
                PRICE_LINE="$PRICE_LINE."
            fi
        fi
        PRICE_LINE="$PRICE_LINE Use analyst high target or internal guidance target as primary valuation anchors; use analyst mean only as lagging context."
    fi
fi
SYNTHESIS_PROMPT="$SYNTHESIS_PROMPT

$REFERENCE_DATE_LINE"
[ -n "$PRICE_LINE" ] && SYNTHESIS_PROMPT="$SYNTHESIS_PROMPT

$PRICE_LINE"
FULL_SYNTHESIS_PROMPT="$SYNTHESIS_PROMPT

=== 8 FRAMEWORK ANALYSES ===
$ALL_OUTPUTS"

# Require at least one framework output so synthesis has content (avoid calling API with empty analyses)
FW_COUNT=$(for fw_id in "${FW_SEQUENCE[@]}"; do [ -f "$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md" ] && echo 1; done | wc -l)
[ "${FW_COUNT:-0}" -eq 0 ] && { echo "ERROR: No framework outputs found; run frameworks first. Expected at least one of: ${OUTPUTS_DIR}/${TICKER_UPPER}_*.md" >&2; exit 1; }

# Call API for synthesis (use same high limit as frameworks to avoid truncating verdict)
log_trace "INFO" "09-synthesis" "Starting..."
RESPONSE=$(call_llm_api "$FULL_SYNTHESIS_PROMPT" 8192)
CONTENT=$(extract_content "$RESPONSE")
read INPUT_TOKENS OUTPUT_TOKENS <<< "$(extract_usage "$RESPONSE" "$FULL_SYNTHESIS_PROMPT")"

# Guard: API can return 200 with empty candidates (e.g. safety block); avoid overwriting with empty file
if [ -z "${CONTENT//[[:space:]]/}" ]; then
    log_trace "ERROR" "09-synthesis" "Empty synthesis response"
    echo "ERROR: Synthesis API returned no content (empty or blocked response). Check API response or try again." >&2
    exit 1
fi

# Save results (single final report only)
echo "$CONTENT" > "$OUTPUTS_DIR/${TICKER_UPPER}_FINAL_REPORT.md"
log_trace "INFO" "09-synthesis" "Complete | ${INPUT_TOKENS}i/${OUTPUT_TOKENS}o"

# Log synthesis cost
log_cost "$TICKER_UPPER" "09-synthesis" "$INPUT_TOKENS" "$OUTPUT_TOKENS"

echo ""
echo "======================================"
echo "  SYNTHESIS & VERDICT"
echo "======================================"
echo ""
echo "$CONTENT"
echo ""
echo "======================================"
echo "✅ ANALYSIS COMPLETE"
echo "======================================"
echo "Report: $OUTPUTS_DIR/${TICKER_UPPER}_FINAL_REPORT.md"
