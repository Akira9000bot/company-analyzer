#!/bin/bash
#
# lib/api-client.sh - Google Gemini API client with retry logic and rate limiting
#

# Source tracing library
source "$(dirname "${BASH_SOURCE[0]}")/trace.sh"

AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_PROFILES" ]; then
    GEMINI_API_KEY=$(jq -r '.profiles["google:default"].key // .profiles["gemini:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")
    export GEMINI_API_KEY
fi

API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
MODEL="gemini-2.0-flash"
MAX_RETRIES=3
RETRY_DELAY_BASE=2

# Rate limiting for Gemini Free Tier (15 requests/minute)
GEMINI_REQ_COUNT=0
GEMINI_REQ_WINDOW_START=$(date +%s)
GEMINI_MAX_RPM=15

check_api_key() {
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        log_trace "ERROR" "API" "GEMINI_API_KEY not set"
        return 1
    fi
    return 0
}

# Alias for backward compatibility
validate_api_key() {
    check_api_key
}

# Check and enforce rate limit
enforce_rate_limit() {
    local now=$(date +%s)
    local window_elapsed=$((now - GEMINI_REQ_WINDOW_START))
    
    # Reset window every 60 seconds
    if [ $window_elapsed -ge 60 ]; then
        GEMINI_REQ_COUNT=0
        GEMINI_REQ_WINDOW_START=$now
    fi
    
    # If at limit, wait until window resets
    if [ $GEMINI_REQ_COUNT -ge $GEMINI_MAX_RPM ]; then
        local wait_time=$((60 - window_elapsed + 1))
        log_trace "WARN" "RATE" "Rate limit reached. Waiting ${wait_time}s..."
        sleep $wait_time
        # Reset after wait
        GEMINI_REQ_COUNT=0
        GEMINI_REQ_WINDOW_START=$(date +%s)
    fi
    
    GEMINI_REQ_COUNT=$((GEMINI_REQ_COUNT + 1))
}

call_gemini_api() {
    local prompt="$1"
    local max_tokens="${2:-800}"
    local attempt=1
    local delay=$RETRY_DELAY_BASE
    
    if ! check_api_key; then return 1; fi
    
    # Enforce rate limit before calling
    enforce_rate_limit
    
    # Build JSON payload for Gemini API
    local json_payload=$(jq -n \
        --arg text "$prompt" \
        --argjson max_tokens "$max_tokens" \
        '{
            contents: [{parts: [{text: $text}]}],
            generationConfig: {
                maxOutputTokens: $max_tokens,
                temperature: 0.3
            }
        }')
    
    while [ $attempt -le $MAX_RETRIES ]; do
        log_trace "API" "${FW_ID:-CMD}" "Calling Gemini (Attempt $attempt)..."
        dump_raw "${TICKER_UPPER:-GLOBAL}" "${FW_ID:-CMD}" "req" "$json_payload"
        
        local start_time=$(date +%s.%N)
        local response=$(curl -s --max-time 60 -X POST "${API_URL}?key=${GEMINI_API_KEY}" \
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
        
        # Check for rate limit (429)
        if [ "$http_code" = "429" ]; then
            log_trace "WARN" "${FW_ID:-CMD}" "Rate limited (429). Waiting 60s..."
            sleep 60
            # Reset rate limit tracking
            GEMINI_REQ_COUNT=0
            GEMINI_REQ_WINDOW_START=$(date +%s)
            attempt=$((attempt + 1))
            continue
        fi
        
        log_trace "WARN" "${FW_ID:-CMD}" "API Failure (HTTP $http_code)"
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            sleep $delay
            delay=$((delay * 2))
            attempt=$((attempt + 1))
        else
            return 1
        fi
    done
    return 1
}

# Keep function name for backward compatibility
call_moonshot_api() {
    call_gemini_api "$@"
}

extract_content() {
    echo "$1" | jq -r '.candidates[0].content.parts[0].text // empty'
}

extract_usage() {
    # Gemini provides token counts differently
    local input=$(echo "$1" | jq -r '.usageMetadata.promptTokenCount // 0')
    local output=$(echo "$1" | jq -r '.usageMetadata.candidatesTokenCount // 0')
    # Handle case where usageMetadata might be missing
    if [ "$input" = "null" ] || [ -z "$input" ]; then
        input=0
    fi
    if [ "$output" = "null" ] || [ -z "$output" ]; then
        output=0
    fi
    echo "$input $output"
}

# Alias for backward compatibility
extract_tokens() {
    extract_usage "$@"
}

# Export functions if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f check_api_key validate_api_key call_gemini_api call_moonshot_api extract_content extract_usage extract_tokens enforce_rate_limit
fi