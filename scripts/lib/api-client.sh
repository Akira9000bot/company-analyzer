#!/bin/bash
#
# lib/api-client.sh - Dynamic, Configuration-Driven API Client
# Optimized for High-Density Financial Analysis and TPM Resilience.
#

source "$(dirname "${BASH_SOURCE[0]}")/trace.sh"

# 1. DYNAMIC CONFIGURATION LOADER
CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"

# Extract Model and RPM directly from config
# Logic handles both "provider/model" and "model" formats
RAW_MODEL=$(jq -r '.agents.defaults.model.primary // "gemini-3-flash-preview"' "$CONFIG_FILE")
MODEL_NAME=$(echo "$RAW_MODEL" | awk -F'/' '{print $NF}')
GEMINI_MAX_RPM=$(jq -r '.gateway.nodes.rateLimit.requestsPerMinute // 250' "$CONFIG_FILE")
API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL_NAME}:generateContent"

# 2. AUTHENTICATION
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
        log_trace "ERROR" "API" "API Key not found for $MODEL_NAME"
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
        log_trace "WARN" "RATE" "Throttling $MODEL_NAME: Waiting ${wait_time}s..."
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
        log_trace "API" "${FW_ID:-CMD}" "Calling $MODEL_NAME (Attempt $attempt)..."
        
        local response=$(curl -s --max-time 90 -X POST "${API_URL}?key=${GEMINI_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            -w "\n%{http_code}")
        
        local http_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | sed '$d')
        
        # 1. Success
        if [ "$http_code" = "200" ]; then
            echo "$body"
            return 0
        fi
        
        # 2. Critical Rate Limit (429) - THE 61S NUKE
        if [ "$http_code" = "429" ]; then
            log_trace "WARN" "RATE" "TPM Exhausted. Forcing 61s window reset..."
            sleep 61
            attempt=$((attempt + 1))
            continue
        fi
        
        # 3. Transient Server Errors (500+)
        if [[ "$http_code" -ge 500 ]]; then
            log_trace "WARN" "API" "Server error (HTTP $http_code). Retrying..."
            sleep $((RETRY_DELAY_BASE * attempt))
            attempt=$((attempt + 1))
        else
            # 4. Fatal Errors (400, 401, 403, 404)
            log_trace "ERROR" "API" "Fatal HTTP $http_code: $body"
            return 1
        fi
    done
    return 1
}

# --- Aliases & Helpers ---
extract_content() { echo "$1" | jq -r '.candidates[0].content.parts[0].text // empty'; }

extract_usage() { 
    local prompt_t=$(echo "$1" | jq -r '.usageMetadata.promptTokenCount // 0')
    local cand_t=$(echo "$1" | jq -r '.usageMetadata.candidatesTokenCount // 0')
    
    # Proactive TPM Monitoring
    if [ "$prompt_t" -gt 100000 ]; then
        log_trace "WARN" "TPM" "Heavy payload detected: ${prompt_t} tokens."
    fi
    echo "$prompt_t $cand_t" 
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f call_llm_api extract_content extract_usage
fi