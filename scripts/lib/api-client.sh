#!/bin/bash
#
# lib/api-client.sh - Configuration-driven LLM API client.
# Uses OpenClaw config for model, provider base URL, and auth. No hardcoded provider or keys.
#

source "$(dirname "${BASH_SOURCE[0]}")/trace.sh"

# 1. CONFIG (OpenClaw paths; override via env if needed)
CONFIG_FILE="${OPENCLAW_CONFIG:-${HOME}/.openclaw/openclaw.json}"
AUTH_PROFILES="${OPENCLAW_AUTH_PROFILES:-${HOME}/.openclaw/agents/main/agent/auth-profiles.json}"

# Model: agents.defaults.model.primary (e.g. "provider/model-id")
RAW_MODEL=$(jq -r '.agents.defaults.model.primary // empty' "$CONFIG_FILE" 2>/dev/null)
[ -z "$RAW_MODEL" ] && RAW_MODEL="google/gemini-3-flash-preview"
PROVIDER=$(echo "$RAW_MODEL" | awk -F'/' '{print $1}')
MODEL_ID=$(echo "$RAW_MODEL" | awk -F'/' '{print $NF}')
MODEL_NAME="${MODEL_ID:-unknown}"

# API URL: models.providers[provider].baseUrl from config
BASE_URL=$(jq -r --arg p "$PROVIDER" '.models.providers[$p].baseUrl // empty' "$CONFIG_FILE" 2>/dev/null)
[ -z "$BASE_URL" ] && BASE_URL="https://generativelanguage.googleapis.com/v1beta"
API_URL="${BASE_URL%/}/models/${MODEL_ID}:generateContent"

LLM_MAX_RPM=$(jq -r '.gateway.nodes.rateLimit.requestsPerMinute // 250' "$CONFIG_FILE" 2>/dev/null)
[ -z "$LLM_MAX_RPM" ] || ! [[ "$LLM_MAX_RPM" =~ ^[0-9]+$ ]] && LLM_MAX_RPM=250

# 2. AUTH: profile key = "{provider}:default"
if [ -f "$AUTH_PROFILES" ]; then
    LLM_API_KEY=$(jq -r --arg p "$PROVIDER" '.profiles[$p + ":default"].key // empty' "$AUTH_PROFILES" 2>/dev/null)
    export LLM_API_KEY
fi

# 3. RESILIENCE CONFIG
MAX_RETRIES=5
RETRY_DELAY_BASE=2
RETRY_DELAY_503=8

# 4. RATE LIMITING STATE
LLM_REQ_COUNT=0
LLM_REQ_WINDOW_START=$(date +%s)

check_api_key() {
    if [ -z "${LLM_API_KEY:-}" ]; then
        log_trace "ERROR" "API" "API key not found for provider $PROVIDER (profile ${PROVIDER}:default)"
        return 1
    fi
    return 0
}

enforce_rate_limit() {
    local now=$(date +%s)
    local window_elapsed=$((now - LLM_REQ_WINDOW_START))
    
    if [ $window_elapsed -ge 60 ]; then
        LLM_REQ_COUNT=0
        LLM_REQ_WINDOW_START=$now
    fi
    
    if [ $LLM_REQ_COUNT -ge $LLM_MAX_RPM ]; then
        local wait_time=$((60 - window_elapsed + 1))
        log_trace "WARN" "RATE" "Throttling $MODEL_NAME: Waiting ${wait_time}s..."
        sleep $wait_time
        LLM_REQ_COUNT=0
        LLM_REQ_WINDOW_START=$(date +%s)
    fi
    LLM_REQ_COUNT=$((LLM_REQ_COUNT + 1))
}

call_llm_api() {
    local prompt="$1"
    local max_tokens="${2:-8192}"
    local attempt=1
    
    check_api_key || return 1
    enforce_rate_limit
    
    # Ensure max_tokens is a valid positive integer (0 or empty can break jq/API); default 8192 so output is not truncated
    local clean_tokens=$(echo "$max_tokens" | grep -oE '^[0-9]+' || echo "8192")
    [ -z "$clean_tokens" ] && clean_tokens=8192
    [ "${clean_tokens:-0}" -le 0 ] 2>/dev/null && clean_tokens=8192

    local json_payload=$(jq -n \
        --arg text "$prompt" \
        --argjson max_tokens "$clean_tokens" \
        '{
            contents: [{parts: [{text: $text}]}],
            generationConfig: {
                maxOutputTokens: $max_tokens,
                temperature: 0.5
            }
        }')
    
    while [ $attempt -le $MAX_RETRIES ]; do
        log_trace "API" "${FW_ID:-CMD}" "Calling $MODEL_NAME (Attempt $attempt)..."
        
        local response=$(curl -s --max-time 90 -X POST "${API_URL}?key=${LLM_API_KEY}" \
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
        
        # 2b. Billing / quota (402, 403 with billing message) - do not retry
        if [ "$http_code" = "402" ] || [ "$http_code" = "403" ]; then
            if echo "$body" | grep -qiE 'billing|quota|credit|balance|insufficient'; then
                log_trace "ERROR" "API" "Billing/quota (HTTP $http_code). Top up or switch API key."
                echo "ERROR: API billing/quota (HTTP $http_code). Check your provider's billing dashboard and top up or switch the key in OpenClaw auth profiles." >&2
                return 1
            fi
        fi
        
        # 3. Transient Server Errors (500+)
        if [[ "$http_code" -ge 500 ]]; then
            log_trace "WARN" "API" "Server error (HTTP $http_code). Retrying $attempt/$MAX_RETRIES..."
            if [ "$attempt" -eq "$MAX_RETRIES" ]; then
                log_trace "ERROR" "API" "Failed after $MAX_RETRIES attempts (last HTTP $http_code). Try again later."
                echo "ERROR: LLM API failed after $MAX_RETRIES attempts (last HTTP $http_code). Try again later." >&2
            fi
            if [ "$http_code" = "503" ]; then
                sleep $((RETRY_DELAY_503 * attempt))
            else
                sleep $((RETRY_DELAY_BASE * attempt))
            fi
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
# Concatenate all content parts (API may return multiple parts; using only [0] can truncate)
extract_content() {
    echo "$1" | jq -r '
        if .candidates[0].content.parts then
            [.candidates[0].content.parts[].text // ""] | join("")
        else
            .candidates[0].content.parts[0].text // empty
        end
    '
}

# Extract why generation stopped (for truncation diagnostics). Echo: "finishReason outputTokens"
extract_finish_info() {
    local api_response="$1"
    local max_output_tokens="${2:-}"
    local reason out_tokens
    reason=$(echo "$api_response" | jq -r '.candidates[0].finishReason // .candidates[0].finish_reason // "UNKNOWN"' 2>/dev/null)
    out_tokens=$(echo "$api_response" | jq -r '.usageMetadata.candidatesTokenCount // .usageMetadata.candidates_token_count // empty' 2>/dev/null)
    [ -z "$out_tokens" ] && out_tokens="?"
    echo "$reason $out_tokens $max_output_tokens"
}

# Use API-reported token counts when present (accurate billing). Fallback: word-count estimate.
extract_usage() { 
    # Args:
    #   $1 = raw API response JSON from call_llm_api
    #   $2 = original prompt text that was sent
    local api_response="$1"
    local prompt_text="$2"

    # 1. Prefer API usageMetadata when present (actual tokens; cost is based on this)
    local api_prompt api_cand
    api_prompt=$(echo "$api_response" | jq -r '.usageMetadata.promptTokenCount // .usageMetadata.prompt_token_count // empty' 2>/dev/null)
    api_cand=$(echo "$api_response" | jq -r '.usageMetadata.candidatesTokenCount // .usageMetadata.candidates_token_count // empty' 2>/dev/null)
    if [[ -n "$api_prompt" && -n "$api_cand" ]] && [[ "$api_prompt" =~ ^[0-9]+$ && "$api_cand" =~ ^[0-9]+$ ]]; then
        if [ "$api_prompt" -gt 100000 ]; then
            log_trace "WARN" "TPM" "Heavy payload: ${api_prompt} input tokens."
        fi
        echo "$api_prompt $api_cand"
        return
    fi

    # 2. Fallback: estimate from word count (when API does not return usageMetadata)
    local cand_text
    cand_text=$(echo "$api_response" | jq -r '
        if .candidates[0].content.parts then
            [.candidates[0].content.parts[].text // ""] | join("")
        else
            .candidates[0].content.parts[0].text // empty
        end
    ')

    local prompt_words cand_words
    local prompt_tokens cand_tokens

    if [[ -n "$prompt_text" ]]; then
        prompt_words=$(wc -w <<<"$prompt_text")
        prompt_words=${prompt_words//[[:space:]]/}
        [[ -z "$prompt_words" ]] && prompt_words=0
    else
        prompt_words=0
    fi
    prompt_tokens=$(( 2 * prompt_words ))

    if [[ -n "$cand_text" ]]; then
        cand_words=$(wc -w <<<"$cand_text")
        cand_words=${cand_words//[[:space:]]/}
        [[ -z "$cand_words" ]] && cand_words=0
    else
        cand_words=0
    fi
    cand_tokens=$(( 2 * cand_words ))

    if [ "$prompt_tokens" -gt 100000 ]; then
        log_trace "WARN" "TPM" "Heavy payload detected: ${prompt_tokens} tokens (approx 2x words)."
    fi
    echo "$prompt_tokens $cand_tokens"
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f call_llm_api extract_content extract_usage extract_finish_info
fi