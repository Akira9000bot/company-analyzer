#!/bin/bash
#
# lib/trace.sh - Deep Trace Logging for company-analyzer
#

# Get the directory where this script is located
TRACE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_DIR="$(dirname "$TRACE_LIB_DIR")/../assets/traces"
RAW_DIR="$TRACE_DIR/raw"

# Initialize trace directories
init_trace() {
    mkdir -p "$RAW_DIR"
}

# Log a trace event
# Usage: log_trace "LEVEL" "COMPONENT" "MESSAGE"
log_trace() {
    local level="$1"
    local component="$2"
    local message="$3"
    local timestamp=$(date +%H:%M:%S)
    local trace_file="$TRACE_DIR/${TICKER_UPPER:-GLOBAL}_$(date +%Y-%m-%d).trace"
    
    printf "[%s] %-6s | %-12s | %s\n" "$timestamp" "$level" "$component" "$message" >> "$trace_file"
}

# Dump raw JSON wire data
# Usage: dump_raw "ticker" "fw_id" "type" "json_content"
# type: "req" or "res"
dump_raw() {
    local ticker="$1"
    local fw_id="$2"
    local type="$3"
    local content="$4"
    local raw_file="$RAW_DIR/${ticker}_${fw_id}_${type}.json"
    
    echo "$content" > "$raw_file"
}
