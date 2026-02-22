#!/bin/bash
#
# synthesize.sh - Prepare synthesis input from all frameworks
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"

TICKER="${1:-}"
[ -z "$TICKER" ] && { echo "Usage: ./synthesize.sh <TICKER>"; exit 1; }

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# Check all 8 frameworks exist
echo "Checking framework outputs..."
FRAMEWORKS_FOUND=0
SYNTHESIS_INPUT=""

for i in 01 02 03 04 05 06 07 08; do
    FILE=$(ls "$OUTPUTS_DIR"/${TICKER_UPPER}_${i}-*.md 2>/dev/null | head -1)
    if [ -f "$FILE" ]; then
        FRAMEWORKS_FOUND=$((FRAMEWORKS_FOUND + 1))
        echo "  ✓ $i"
    else
        echo "  ✗ $i (missing)"
    fi
done

echo ""
echo "Frameworks: $FRAMEWORKS_FOUND/8"

# Build synthesis input
SYNTHESIS_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_synthesis_input.txt"
{
    echo "# Synthesis Input: $TICKER_UPPER"
    echo "Generated: $(date)"
    echo ""
    echo "## All 8 Framework Summaries"
    echo ""
    
    for i in 01 02 03 04 05 06 07 08; do
        FILE=$(ls "$OUTPUTS_DIR"/${TICKER_UPPER}_${i}-*.md 2>/dev/null | head -1)
        if [ -f "$FILE" ]; then
            echo "### Framework $i"
            head -50 "$FILE"
            echo ""
            echo "---"
            echo ""
        fi
    done
    
    echo ""
    echo "## Synthesis Instructions"
    echo ""
    echo "Generate investment thesis with:"
    echo "- Verdict: BUY / HOLD / SELL"
    echo "- Confidence: High/Medium/Low"
    echo "- Key contradictions between frameworks"
    echo "- Primary risk factor"
    
} > "$SYNTHESIS_FILE"

OUTPUT_FILE="$OUTPUTS_DIR/${TICKER_UPPER}_SYNTHESIS.md"
{
    echo "# Investment Thesis: $TICKER_UPPER"
    echo ""
    echo "**Status:** Synthesis input prepared"
    echo "**Frameworks:** $FRAMEWORKS_FOUND/8 analyzed"
    echo "**Model:** moonshot/kimi-k2.5"
    echo ""
    echo "## Synthesis Input"
    echo "$SYNTHESIS_FILE"
    echo ""
    echo "## To Generate Live Thesis"
    echo "Run: ./synthesize-live.sh $TICKER_UPPER --live"
    echo ""
    echo "---"
    echo "*Generated: $(date)*"
} > "$OUTPUT_FILE"

echo ""
echo "======================================"
echo "SYNTHESIS PREPARED"
echo "======================================"
echo ""
echo "Output: $OUTPUT_FILE"
echo "Input: $SYNTHESIS_FILE ($(wc -w < "$SYNTHESIS_FILE") words)"
echo ""
echo "Frameworks included: $FRAMEWORKS_FOUND/8"
echo ""
echo "To generate with LIVE API:"
echo "  ./synthesize-live.sh $TICKER_UPPER"
