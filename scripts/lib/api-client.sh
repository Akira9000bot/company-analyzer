#!/bin/bash
#
# lib/api-client.sh - Moonshot API client with retry logic and tracing
#

# Source tracing library
source "$(dirname "${BASH_SOURCE[0]}")/trace.sh"

AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_PROFILES" ]; then
    MOONSHOT_API_KEY=$(jq -r '.profiles["moonshot:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")
    export MOONSHOT_API_KEY
fi

API_URL="https://api.moonshot.ai/v1/chat/completions"
MODEL="kimi-k2.5"
MAX_RETRIES=3
RETRY_DELAY_BASE=2

check_api_key() {
    if [ -z "${MOONSHOT_API_KEY:-}" ]; then
        log_trace "ERROR" "API" "MOONSHOT_API_KEY not set"
        return 1
    fi
    return 0
}

# Alias for backward compatibility
validate_api_key() {
    check_api_key
}

call_moonshot_api() {
    local prompt="$1"
    local attempt=1
    local delay=$RETRY_DELAY_BASE
    
    if ! check_api_key; then return 1; fi
    
    local json_payload=$(jq -n \
        --arg model "$MODEL" \
        --arg content "$prompt" \
        '{model: $model, messages: [{role: "user", content: $content}]}')
    
    while [ $attempt -le $MAX_RETRIES ]; do
        log_trace "API" "${FW_ID:-CMD}" "Calling Moonshot (Attempt $attempt)..."
        dump_raw "${TICKER_UPPER:-GLOBAL}" "${FW_ID:-CMD}" "req" "$json_payload"
        
        local start_time=$(date +%s.%N)
        local response=$(curl -s --max-time 60 -X POST "$API_URL" \
            -H "Authorization: Bearer $MOONSHOT_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            -w "\n%{http_code}" 2>/dev/null)
        local end_time=$(date +%s.%N)
        local latency=$(echo "$end_time - $start_time" | bc)
        
        local http_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | sed '$d')
        
        dump_raw "${TICKER_UPPER:-GLOBAL}" "${FW_ID:-CMD}" "res" "$body"
        
        if [ "$http_code" = "200" ]; then
            log_trace "API" "${FW_ID:-CMD}" "SUCCESS | Latency: ${latency}s"
            echo "$body"
            return 0
        fi
        
        log_trace "WARN" "${FW_ID:-CMD}" "API Failure (HTTP $http_code)"
        
        if [ "$http_code" = "429" ] || [ $attempt -lt $MAX_RETRIES ]; then
            sleep $delay
            delay=$((delay * 2))
            attempt=$((attempt + 1))
        else
            return 1
        fi
    done
    return 1
}

extract_content() {
    echo "$1" | jq -r '.choices[0].message.content // empty'
}

extract_usage() {
    local input=$(echo "$1" | jq -r '.usage.prompt_tokens // 0')
    local output=$(echo "$1" | jq -r '.usage.completion_tokens // 0')
    echo "$input $output"
}

# Alias for backward compatibility
extract_tokens() {
    extract_usage "$@"
}

# Export functions if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f check_api_key validate_api_key call_moonshot_api extract_content extract_usage extract_tokens
fi
