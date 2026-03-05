#!/bin/bash
#
# lib/trace.sh - Trace logging for company-analyzer
# All traces live under assets/traces/ as <TICKER>_<date>.trace
#

TRACE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_DIR="$(dirname "$TRACE_LIB_DIR")/../assets/traces"

# Ensure trace directory exists
init_trace() {
    mkdir -p "$TRACE_DIR"
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
