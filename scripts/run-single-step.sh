#!/bin/bash
# run-single-step.sh - Run one framework step (e.g. 01-phase only). No --live flag.
# Use this when you want a single prompt (e.g. 01-phase) without the full pipeline or synthesis.
#
# Usage: run-single-step.sh <TICKER> <FW_ID>
# Example: run-single-step.sh KVYO 01-phase

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
PROMPTS_DIR="$SKILL_DIR/references/prompts"
OUTPUTS_DIR="$SKILL_DIR/assets/outputs"

TICKER="${1:-}"
FW_ID="${2:-}"

if [[ -z "$TICKER" || -z "$FW_ID" ]]; then
    echo "Usage: run-single-step.sh <TICKER> <FW_ID>" >&2
    echo "Example: run-single-step.sh KVYO 01-phase" >&2
    exit 1
fi

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# Synthesis (09) needs all 8 framework outputs; use analyze.sh or pipeline instead
if [ "$FW_ID" = "09-synthesis" ]; then
    echo "ERROR: 09-synthesis requires all 8 framework outputs. Use analyze.sh or analyze-pipeline.sh for full analysis." >&2
    exit 1
fi

PROMPT_FILE="$PROMPTS_DIR/${FW_ID}.txt"
if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
    exit 1
fi

# Ensure data file exists (fetch if missing) so first trace line is the data check
source "$SCRIPT_DIR/lib/trace.sh"
DATA_FILE="$SKILL_DIR/.cache/data/${TICKER_UPPER}_data.json"
init_trace
if [ ! -f "$DATA_FILE" ]; then
    log_trace "INFO" "data" "Data file not found; fetching..."
    echo "📊 Data file not found; fetching for $TICKER_UPPER..."
    "$SCRIPT_DIR/fetch_data.sh" "$TICKER_UPPER" || { echo "ERROR: fetch_data.sh failed for $TICKER_UPPER" >&2; exit 1; }
else
    log_trace "INFO" "data" "Data file exists."
fi
[ ! -f "$DATA_FILE" ] && { echo "ERROR: No data file after fetch: $DATA_FILE" >&2; exit 1; }

exec "$SCRIPT_DIR/run-framework.sh" "$TICKER_UPPER" "$FW_ID" "$PROMPT_FILE" "$OUTPUTS_DIR"
