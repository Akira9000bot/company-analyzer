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
WEIGHTS_FILE="$(dirname "$PROMPTS_DIR")/framework-weights.json"
REFERENCE_DATE=$(date -u +%Y-%m-%d)

# Compute BASE_SCORE from the 7 scored frameworks (exclude 05-sentiment)
BASE_SCORE_VAL=""
if [ -f "$WEIGHTS_FILE" ]; then
    WEIGHTED_SUM="0"
    WEIGHT_TOTAL="0"
    SCORED_FRAMEWORKS=(01-phase 02-metrics 03-ai-moat 04-strategic-moat 06-growth 07-business 08-risk)
    for fw_id in "${SCORED_FRAMEWORKS[@]}"; do
        FW_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_${fw_id}.md"
        if [ -f "$FW_FILE" ]; then
            SCORE=$(grep -oE 'FRAMEWORK_SCORE:[[:space:]]*[0-9]+' "$FW_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
            W=$(jq -r --arg k "$fw_id" '.[$k] // 0' "$WEIGHTS_FILE" 2>/dev/null)
            if [[ -n "$SCORE" && "$SCORE" =~ ^[0-9]+$ ]] && [[ -n "$W" && "$W" =~ ^[0-9.]+$ ]] && [ "$(echo "$W > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
                WEIGHTED_SUM=$(echo "scale=4; $WEIGHTED_SUM + $SCORE * $W" | bc 2>/dev/null || echo "$WEIGHTED_SUM")
                WEIGHT_TOTAL=$(echo "scale=4; $WEIGHT_TOTAL + $W" | bc 2>/dev/null || echo "$WEIGHT_TOTAL")
            fi
        fi
    done
    if [[ -n "$WEIGHT_TOTAL" && "$WEIGHT_TOTAL" != "0" ]] && [[ -n "$WEIGHTED_SUM" ]]; then
        BASE_SCORE_RAW=$(echo "scale=2; $WEIGHTED_SUM / $WEIGHT_TOTAL" | bc 2>/dev/null || echo "")
        if [[ -n "$BASE_SCORE_RAW" && "$BASE_SCORE_RAW" =~ ^[0-9.]+$ ]]; then
            BASE_SCORE_VAL=$(echo "scale=0; $BASE_SCORE_RAW / 1" | bc 2>/dev/null || echo "")
        fi
    fi
fi

# Inject valuation anchors from data so synthesis uses the conservative primary anchor, not a lagging mean target
PRICE_LINE=""
CHEAP_DEFINITION_LINE=""
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
            PRICE_LINE="$PRICE_LINE Analyst high target (candidate primary anchor): \$${TARGET_HIGH_FMT}."
        fi
        if [ -n "$INTERNAL_GUIDANCE_TARGET" ] && [ "$INTERNAL_GUIDANCE_TARGET" != "null" ] && [ "$INTERNAL_GUIDANCE_TARGET" != "N/A" ]; then
            INTERNAL_FMT=$(printf "%.2f" "$INTERNAL_GUIDANCE_TARGET" 2>/dev/null || echo "$INTERNAL_GUIDANCE_TARGET")
            PRICE_LINE="$PRICE_LINE Internal guidance target (candidate primary anchor): \$${INTERNAL_FMT}"
            if [ -n "$GUIDANCE_EPS" ] && [ "$GUIDANCE_EPS" != "null" ] && [ "$GUIDANCE_EPS" != "N/A" ] && [ -n "$GUIDANCE_MULTIPLE" ] && [ "$GUIDANCE_MULTIPLE" != "null" ] && [ "$GUIDANCE_MULTIPLE" != "N/A" ]; then
                PRICE_LINE="$PRICE_LINE from guidance EPS ${GUIDANCE_EPS} x ${GUIDANCE_MULTIPLE}x."
            else
                PRICE_LINE="$PRICE_LINE."
            fi
        fi
        if [ -n "$PRIMARY_ANCHOR" ] && [ "$PRIMARY_ANCHOR" != "null" ] && [ "$PRIMARY_ANCHOR" != "N/A" ] && [ -n "$PRIMARY_ANCHOR_SOURCE" ] && [ "$PRIMARY_ANCHOR_SOURCE" != "null" ] && [ "$PRIMARY_ANCHOR_SOURCE" != "N/A" ]; then
            PRIMARY_FMT=$(printf "%.2f" "$PRIMARY_ANCHOR" 2>/dev/null || echo "$PRIMARY_ANCHOR")
            PRICE_LINE="$PRICE_LINE Conservative primary valuation anchor: \$${PRIMARY_FMT} (${PRIMARY_ANCHOR_SOURCE})."
            # Discount to anchor for Step 4b "Cheap" definition (strict: ≥15% below anchor)
            if [[ "$CURRENT_PRICE" =~ ^[0-9.]+$ ]] && [[ "$PRIMARY_ANCHOR" =~ ^[0-9.]+$ ]] && [ "$(echo "$PRIMARY_ANCHOR > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
                DISCOUNT_PCT=$(echo "scale=2; ($PRIMARY_ANCHOR - $CURRENT_PRICE) * 100 / $PRIMARY_ANCHOR" | bc 2>/dev/null || echo "")
                [ -n "$DISCOUNT_PCT" ] && PRICE_LINE="$PRICE_LINE Discount to primary anchor: ${DISCOUNT_PCT}%."
            fi
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
        PRICE_LINE="$PRICE_LINE Use the lower of analyst high target and internal guidance target as the primary valuation anchor; use analyst mean only as lagging context."
    fi
    # Inject ROA, ROIC (when present), and revenue growth for Phase 4/5 guardrails (capital-efficiency and maturity cap)
    ROA_PCT=$(jq -r '.financial_metrics.roa // empty' "$DATA_FILE" 2>/dev/null | sed 's/%//')
    ROIC_PCT=$(jq -r '.financial_metrics.roic // empty' "$DATA_FILE" 2>/dev/null | sed 's/%//')
    REV_YOY=$(jq -r '.financial_metrics.revenue_yoy // empty' "$DATA_FILE" 2>/dev/null)
    REV_Q_YOY=$(jq -r '.financial_metrics.revenue_q_yoy // empty' "$DATA_FILE" 2>/dev/null)
    GUARDRAIL_LINE=""
    # Only treat ROIC as "present" when not missing: exclude empty, "null", and "N/A" (avoids zero-vs-null trap; 0 is a valid value)
    ROIC_PRESENT="0"
    if [[ -n "$ROIC_PCT" && "$ROIC_PCT" != "null" && "$ROIC_PCT" != "N/A" ]]; then
        ROIC_PRESENT="1"
    fi
    if [[ -n "$ROA_PCT" && "$ROA_PCT" != "null" ]] || [[ "$ROIC_PRESENT" = "1" ]]; then
        GUARDRAIL_LINE="GUARDRAIL DATA:"
        [[ -n "$ROA_PCT" && "$ROA_PCT" != "null" ]] && GUARDRAIL_LINE="$GUARDRAIL_LINE roa_pct: ${ROA_PCT}"
        if [[ "$ROIC_PRESENT" = "1" ]]; then
            [[ -n "$ROA_PCT" && "$ROA_PCT" != "null" ]] && GUARDRAIL_LINE="$GUARDRAIL_LINE,"
            GUARDRAIL_LINE="$GUARDRAIL_LINE roic_pct: ${ROIC_PCT}"
        fi
        if [[ -n "$REV_Q_YOY" && "$REV_Q_YOY" != "null" && "$REV_Q_YOY" != "N/A" ]]; then
            GUARDRAIL_LINE="$GUARDRAIL_LINE, revenue_q_yoy_pct: ${REV_Q_YOY}"
        elif [[ -n "$REV_YOY" && "$REV_YOY" != "null" && "$REV_YOY" != "N/A" ]]; then
            GUARDRAIL_LINE="$GUARDRAIL_LINE, revenue_yoy_pct: ${REV_YOY}"
        fi
        GUARDRAIL_LINE="$GUARDRAIL_LINE. Phase 4/5 ROIC Hard Veto: when roic_pct is present use ROIC (STRONG BUY ≥ 8%; 4-8% cap BUY only if valuation Cheap/Discounted, else cap HOLD; ≤4% cap HOLD). Treat roic_pct as missing (use ROA fallback) only when it is N/A, null, or empty—do not treat the literal 0 as missing. When roic_pct is missing, fall back to roa_pct (STRONG BUY ≥ 6%, cap BUY 3-6%, cap HOLD <3%). Phase 5 maturity cap: STRONG BUY only if revenue growth ≥ 12% or (capital-efficiency metric ≥ threshold and Cheap)."
    fi
    # Strict "Cheap" definition for Step 4b: price must be at least 15% below primary anchor
    if [ -n "$PRIMARY_ANCHOR" ] && [ "$PRIMARY_ANCHOR" != "null" ] && [ "$PRIMARY_ANCHOR" != "N/A" ]; then
        CHEAP_DEFINITION_LINE="PHASE 5 'CHEAP' DEFINITION (Step 4b only): 'Cheap' means strictly: current price is at least 15% below the conservative primary anchor (i.e. discount ≥ 15%). A 2% or 5% discount is NOT Cheap; do not treat small discounts as Cheap."
    fi
fi

# Build injection block at top of prompt (BASE_SCORE, GUARDRAIL DATA, REFERENCE DATE, then weights/price/cheap)
GUARDRAIL_COMPACT=""
[ -n "$ROIC_PCT" ] && [ "$ROIC_PCT" != "null" ] && GUARDRAIL_COMPACT="${GUARDRAIL_COMPACT}roic_pct: ${ROIC_PCT}"
[ -n "$ROA_PCT" ] && [ "$ROA_PCT" != "null" ] && { [ -n "$GUARDRAIL_COMPACT" ] && GUARDRAIL_COMPACT="$GUARDRAIL_COMPACT, "; GUARDRAIL_COMPACT="${GUARDRAIL_COMPACT}roa_pct: ${ROA_PCT}"; }
[ -n "$CURRENT_PRICE" ] && [ "$CURRENT_PRICE" != "null" ] && { [ -n "$GUARDRAIL_COMPACT" ] && GUARDRAIL_COMPACT="$GUARDRAIL_COMPACT, "; GUARDRAIL_COMPACT="${GUARDRAIL_COMPACT}current_price: ${CURRENT_PRICE}"; }
[ -n "$REV_Q_YOY" ] && [ "$REV_Q_YOY" != "N/A" ] && { [ -n "$GUARDRAIL_COMPACT" ] && GUARDRAIL_COMPACT="$GUARDRAIL_COMPACT, "; GUARDRAIL_COMPACT="${GUARDRAIL_COMPACT}revenue_q_yoy_pct: ${REV_Q_YOY}"; }
[ -z "$REV_Q_YOY" ] && [ -n "$REV_YOY" ] && [ "$REV_YOY" != "N/A" ] && { [ -n "$GUARDRAIL_COMPACT" ] && GUARDRAIL_COMPACT="$GUARDRAIL_COMPACT, "; GUARDRAIL_COMPACT="${GUARDRAIL_COMPACT}revenue_yoy_pct: ${REV_YOY}"; }
[ -n "$GUARDRAIL_COMPACT" ] && GUARDRAIL_COMPACT="GUARDRAIL DATA: { $GUARDRAIL_COMPACT }"

INJECTION_TOP=""
[ -n "$BASE_SCORE_VAL" ] && INJECTION_TOP="BASE_SCORE: $BASE_SCORE_VAL"
[ -n "$GUARDRAIL_COMPACT" ] && { [ -n "$INJECTION_TOP" ] && INJECTION_TOP="$INJECTION_TOP
$GUARDRAIL_COMPACT"; [ -z "$INJECTION_TOP" ] && INJECTION_TOP="$GUARDRAIL_COMPACT"; }
[ -n "$INJECTION_TOP" ] && INJECTION_TOP="$INJECTION_TOP
REFERENCE DATE: $REFERENCE_DATE"
[ -z "$INJECTION_TOP" ] && INJECTION_TOP="REFERENCE DATE: $REFERENCE_DATE"
if [ -f "$WEIGHTS_FILE" ]; then
    WEIGHTS_LINE=$(jq -r 'to_entries | map("\(.key)=\(.value * 100 | floor)%") | join(", ")' "$WEIGHTS_FILE" 2>/dev/null || true)
    [ -n "$WEIGHTS_LINE" ] && INJECTION_TOP="$INJECTION_TOP

NUMERIC FRAMEWORK WEIGHTS (total 100% of verdict influence): $WEIGHTS_LINE"
fi
[ -n "$BASE_SCORE_VAL" ] && INJECTION_TOP="$INJECTION_TOP

(Use injected BASE_SCORE in Step 1; do not recalculate. VERDICT TRIGGERS must be relative to REFERENCE DATE above.)"
[ -n "$PRICE_LINE" ] && INJECTION_TOP="$INJECTION_TOP

$PRICE_LINE"
[ -n "$GUARDRAIL_LINE" ] && INJECTION_TOP="$INJECTION_TOP

$GUARDRAIL_LINE"
[ -n "$CHEAP_DEFINITION_LINE" ] && INJECTION_TOP="$INJECTION_TOP

$CHEAP_DEFINITION_LINE"

SYNTHESIS_PROMPT="$INJECTION_TOP

$SYNTHESIS_PROMPT"
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
