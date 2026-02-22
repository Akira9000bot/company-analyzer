#!/bin/bash
#
# Validate Output - Check token limits and quality
#

OUTPUT_FILE="$1"
MAX_TOKENS="${2:-500}"

if [ -z "$OUTPUT_FILE" ] || [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: Output file not found: $OUTPUT_FILE"
    exit 1
fi

WORD_COUNT=$(wc -w < "$OUTPUT_FILE")
TOKEN_ESTIMATE=$(echo "$WORD_COUNT / 0.75" | bc)

echo "Output validation:"
echo "  File: $OUTPUT_FILE"
echo "  Words: $WORD_COUNT"
echo "  Est. tokens: $TOKEN_ESTIMATE"
echo "  Max allowed: $MAX_TOKENS"

if [ "$TOKEN_ESTIMATE" -gt "$MAX_TOKENS" ]; then
    echo "  Status: ❌ FAIL - Exceeds token budget"
    echo "  Truncating..."
    head -c $((MAX_TOKENS * 4)) "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp"
    echo -e "\n\n[TRUNCATED: Exceeded token limit]" >> "${OUTPUT_FILE}.tmp"
    mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
    echo "  Status: ⚠️  Truncated"
    exit 2
else
    echo "  Status: ✅ PASS"
    exit 0
fi
