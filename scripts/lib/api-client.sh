#!/bin/bash
#
# lib/api-client.sh - High-performance Gemini 3 Flash client for Tier 1 Paid
# Optimized for your $400,000 portfolio analysis pipeline.
#

# Source tracing library
source "$(dirname "${BASH_SOURCE[0]}")/trace.sh"

# 1. API Configuration
# Pointing to Gemini 3 Flash Preview (Tier 1 Paid: $0.10/$0.40 per 1M tokens)
MODEL="gemini-3-flash-preview"
API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

# 2. Authentication
AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_PROFILES" ]; then
    # Prioritize google:default profile
    GEMINI_API_KEY=$(jq -r '.profiles["google:default"].key // .profiles["gemini:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")
    export GEMINI_API_KEY
fi

# 3. Resilience Configuration
MAX_RETRIES=3
RETRY_DELAY_BASE=2

# 4. Rate Limiting (Upgraded to Tier 1 Paid Limits)
# Free tier is 15 RPM; Tier 1 Paid is 300 RPM. We use 250 as a safe buffer.
GEMINI_REQ_COUNT=0
GEMINI_REQ_WINDOW_START=$(date +%s)
GEMINI_MAX_RPM=250 

check_api_key() {
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        log_trace "ERROR" "API" "GEMINI_API_KEY not set. Check your auth-profiles.json."
        return 1
    fi
    return 0
}

# Alias for backward compatibility
validate_api_key() { check_api_key; }

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
        log_trace "WARN" "RATE" "Burst limit approaching. Pausing ${wait_time}s..."
        sleep $wait_time
        GEMINI_REQ_COUNT=0
        GEMINI_REQ_WINDOW_START=$(date +%s)
    fi
    
    GEMINI_REQ_COUNT=$((GEMINI_REQ_COUNT + 1))
}

# The Master LLM Function
call_llm_api() {
    local prompt="$1"
    local max_tokens="${2:-800}"
    local attempt=1
    local delay=$RETRY_DELAY_BASE
    
    if ! check_api_key; then return 1; fi
    
    enforce_rate_limit
    
    # Payload optimized for cost control (maxOutputTokens) and precision (temperature)
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
        log_trace "API" "${FW_ID:-CMD}" "Calling ${MODEL} (Attempt $attempt)..."
        
        local start_time=$(date +%s.%N)
        local response=$(curl -s --max-time 60 -X POST "${API_URL}?key=${GEMINI_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            -w "\n%{http_code}" 2>/dev/null)
        local end_time=$(date +%s.%N)
        local latency=$(echo "$end_time - $start_time" | bc)
        
        local http_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ]; then
            log_trace "API" "${FW_ID:-CMD}" "SUCCESS | Latency: ${latency}s"
            echo "$body"
            return 0
        fi
        
        # 429 is common during parallel bursts
        if [ "$http_code" = "429" ]; then
            log_trace "WARN" "${FW_ID:-CMD}" "Rate limited (429). Retrying in 5s..."
            sleep 5
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

# --- Aliases for Backward Compatibility ---
call_gemini_api() { call_llm_api "$@"; }
call_moonshot_api() { call_llm_api "$@"; }

extract_content() {
    # Handles Gemini's specific JSON structure
    echo "$1" | jq -r '.candidates[0].content.parts[0].text // empty'
}

extract_usage() {
    local input=$(echo "$1" | jq -r '.usageMetadata.promptTokenCount // 0')
    local output=$(echo "$1" | jq -r '.usageMetadata.candidatesTokenCount // 0')
    # Cleanup nulls
    [ "$input" = "null" ] && input=0
    [ "$output" = "null" ] && output=0
    echo "$input $output"
}

extract_tokens() { extract_usage "$@"; }

# Export functions if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f check_api_key call_llm_api call_gemini_api call_moonshot_api extract_content extract_usage extract_tokens enforce_rate_limit
fi