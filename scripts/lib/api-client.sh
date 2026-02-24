#!/bin/bash
#
# lib/api-client.sh - Dynamic, Configuration-Driven API Client
#

source "$(dirname "${BASH_SOURCE[0]}")/trace.sh"

# 1. DYNAMIC CONFIGURATION LOADER
# Instead of hardcoding, we pull from your existing OpenClaw config
CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"

# Extract Model and RPM directly from config
MODEL=$(jq -r '.agents.defaults.model.primary // "gemini-3-flash-preview"' "$CONFIG_FILE")
GEMINI_MAX_RPM=$(jq -r '.gateway.nodes.rateLimit.requestsPerMinute // 250' "$CONFIG_FILE")
API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL#*/}:generateContent"

# 2. AUTHENTICATION (Dynamic Key Lookup)
if [ -f "$AUTH_PROFILES" ]; then
    GEMINI_API_KEY=$(jq -r '.profiles["google:default"].key // .profiles["gemini:default"].key // empty' "$AUTH_PROFILES")
    export GEMINI_API_KEY
fi

# 3. RESILIENCE CONFIG
MAX_RETRIES=3
RETRY_DELAY_BASE=2

# 4. RATE LIMITING STATE
GEMINI_REQ_COUNT=0
GEMINI_REQ_WINDOW_START=$(date +%s)

check_api_key() {
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        log_trace "ERROR" "API" "API Key not found for $MODEL"
        return 1
    fi
    return 0
}

enforce_rate_limit() {
    local now=$(date +%s)
    local window_elapsed=$((now - GEMINI_REQ_WINDOW_START))
    
    if [ $window_elapsed -ge 60 ]; then
        GEMINI_REQ_COUNT=0
        GEMINI_REQ_WINDOW_START=$now
    fi
    
    if [ $GEMINI_REQ_COUNT -ge $GEMINI_MAX_RPM ]; then
        local wait_time=$((60 - window_elapsed + 1))
        log_trace "WARN" "RATE" "Throttling $MODEL: Waiting ${wait_time}s..."
        sleep $wait_time
        GEMINI_REQ_COUNT=0
        GEMINI_REQ_WINDOW_START=$(date +%s)
    fi
    GEMINI_REQ_COUNT=$((GEMINI_REQ_COUNT + 1))
}

call_llm_api() {
    local prompt="$1"
    local max_tokens="${2:-800}"
    local attempt=1
    
    check_api_key || return 1
    enforce_rate_limit
    
    # Payload now dynamically accepts temperature from config if present
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
        log_trace "API" "${FW_ID:-CMD}" "Calling $MODEL (Attempt $attempt)..."
        
        local response=$(curl -s --max-time 60 -X POST "${API_URL}?key=${GEMINI_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            -w "\n%{http_code}")
        
        local http_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ]; then
            echo "$body"
            return 0
        fi
        
        # Handle Rate Limiting (429) or Server Errors (500+)
        if [[ "$http_code" == "429" || "$http_code" -ge 500 ]]; then
            log_trace "WARN" "API" "Retrying $MODEL (HTTP $http_code)..."
            sleep $((RETRY_DELAY_BASE * attempt))
            attempt=$((attempt + 1))
        else
            log_trace "ERROR" "API" "Fatal HTTP $http_code"
            return 1
        fi
    done
    return 1
}

# --- Aliases & Helpers ---
call_gemini_api() { call_llm_api "$@"; }
call_moonshot_api() { call_llm_api "$@"; }
extract_content() { echo "$1" | jq -r '.candidates[0].content.parts[0].text // empty'; }
extract_usage() { 
    echo "$1" | jq -r '(.usageMetadata.promptTokenCount // 0 | tostring) + " " + (.usageMetadata.candidatesTokenCount // 0 | tostring)' 
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f call_llm_api extract_content extract_usage
fi