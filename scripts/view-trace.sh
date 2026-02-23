#!/bin/bash
#
# view-trace.sh - Display and analyze trace logs
# Usage: ./view-trace.sh <TICKER> [DATE]
#

set -euo pipefail

TICKER="${1:-}"
DATE="${2:-$(date +%Y-%m-%d)}"

if [ -z "$TICKER" ]; then
    echo "Usage: $0 <TICKER> [YYYY-MM-DD]"
    echo "Examples:"
    echo "  $0 NOW              # View today's trace for NOW"
    echo "  $0 NOW 2026-02-22   # View specific date"
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
TRACE_DIR="$(dirname "$(dirname "$0")")/assets/traces"
TRACE_FILE="$TRACE_DIR/${TICKER_UPPER}_${DATE}.trace"

if [ ! -f "$TRACE_FILE" ]; then
    echo "❌ Trace file not found: $TRACE_FILE"
    echo ""
    echo "Available traces for $TICKER_UPPER:"
    ls -la "$TRACE_DIR/${TICKER_UPPER}"_*.trace 2>/dev/null || echo "  (none found)"
    exit 1
fi

echo "======================================"
echo "  TRACE ANALYSIS: $TICKER_UPPER"
echo "  Date: $DATE"
echo "======================================"
echo ""

# Parse trace into sections
echo "📊 EXECUTION TIMELINE:"
echo ""
grep "^\[" "$TRACE_FILE" | while read line; do
    echo "  $line"
done

echo ""
echo "📈 PERFORMANCE SUMMARY:"
echo ""

# Count cache hits vs API calls
CACHE_HITS=$(grep -c "Cache HIT" "$TRACE_FILE" 2>/dev/null || echo "0")
API_CALLS=$(grep -c "SUCCESS | Latency" "$TRACE_FILE" 2>/dev/null || echo "0")
TOTAL=$((CACHE_HITS + API_CALLS))

if [ $TOTAL -gt 0 ]; then
    echo "  Cache hits:   $CACHE_HITS"
    echo "  API calls:    $API_CALLS"
    echo "  Total:        $TOTAL frameworks"
    echo ""
    
    # Calculate cost savings
    if [ $CACHE_HITS -gt 0 ]; then
        SAVINGS=$(echo "scale=2; $CACHE_HITS * 0.005" | bc 2>/dev/null || echo "?")
        echo "  💰 Estimated savings from cache: ~\$$SAVINGS"
    fi
fi

echo ""
echo "⏱️  LATENCY BREAKDOWN:"
echo ""

# Extract API latencies
grep "Latency:" "$TRACE_FILE" 2>/dev/null | while read line; do
    echo "  $line"
done

echo ""
echo "🚨 ERRORS & WARNINGS:"
echo ""

# Check for errors
ERRORS=$(grep -c "ERROR" "$TRACE_FILE" 2>/dev/null || echo "0")
WARNINGS=$(grep -c "WARN" "$TRACE_FILE" 2>/dev/null || echo "0")

if [ "$ERRORS" -gt 0 ] || [ "$WARNINGS" -gt 0 ]; then
    echo "  Errors:   $ERRORS"
    echo "  Warnings: $WARNINGS"
    echo ""
    grep "ERROR\|WARN" "$TRACE_FILE" | head -10
else
    echo "  ✅ No errors or warnings"
fi

echo ""
echo "📁 RAW DATA LOCATION:"
echo "  $TRACE_DIR/raw/${TICKER_UPPER}_*.json"
echo ""

# Show latest raw files if they exist
RAW_COUNT=$(ls "$TRACE_DIR/raw/${TICKER_UPPER}"_*.json 2>/dev/null | wc -l)
if [ $RAW_COUNT -gt 0 ]; then
    echo "  Available raw dumps: $RAW_COUNT files"
    ls -la "$TRACE_DIR/raw/${TICKER_UPPER}"_*.json 2>/dev/null | head -5
fi

echo ""
echo "======================================"
echo "To view raw JSON: cat $TRACE_DIR/raw/${TICKER_UPPER}_<FW>_res.json"
echo "======================================"
