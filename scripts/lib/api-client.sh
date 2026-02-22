#!/bin/bash
#
# lib/api-client.sh - Moonshot API client with retry logic
#

AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"

# Load API key from auth profiles
load_api_key() {
    if [ -f "$AUTH_PROFILES" ]; then
        MOONSHOT_API_KEY=$(jq -r '.profiles["moonshot:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")
        export MOONSHOT_API_KEY
    fi
    
    if [ -z "${MOONSHOT_API_KEY:-}" ]; then
        echo "❌ Error: MOONSHOT_API_KEY not found in auth profiles"
        return 1
    fi
    
    return 0
}

# Call Moonshot API with retry logic
# Usage: call_moonshot_api <prompt> [model] [max_tokens]
# Returns: JSON response from API
call_moonshot_api() {
    local prompt="$1"
    local model="${2:-kimi-k2.5}"
    local max_tokens="${3:-4000}"
    
    # Ensure API key is loaded
    if [ -z "${MOONSHOT_API_KEY:-}" ]; then
        if ! load_api_key; then
            return 1
        fi
    fi
    
    # Build JSON payload
    local json_payload=$(jq -n \
        --arg model "$model" \
        --arg content "$prompt" \
        --argjson max_tokens "$max_tokens" \
        '{
            model: $model,
            messages: [{role: "user", content: $content}],
            max_tokens: $max_tokens
        }')
    
    local max_retries=3
    local retry_count=0
    local base_delay=2  # Start with 2 seconds
    
    while [ $retry_count -lt $max_retries ]; do
        local response=$(curl -s --max-time 60 -X POST "https://api.moonshot.ai/v1/chat/completions" \
            -H "Authorization: Bearer $MOONSHOT_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$json_payload" 2>&1)
        
        local curl_exit_code=$?
        
        # Check for curl errors (network, timeout, etc.)
        if [ $curl_exit_code -ne 0 ]; then
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                local delay=$((base_delay * (2 ** (retry_count - 1))))
                echo "  ⚠️  Curl error (exit $curl_exit_code), retrying in ${delay}s... (attempt $retry_count/$max_retries)" >&2
                sleep $delay
                continue
            else
                echo "  ❌ Curl failed after $max_retries attempts" >&2
                return 1
            fi
        fi
        
        # Check for API errors
        local error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
        
        if [ -n "$error_msg" ]; then
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                local delay=$((base_delay * (2 ** (retry_count - 1))))
                echo "  ⚠️  API error: $error_msg, retrying in ${delay}s... (attempt $retry_count/$max_retries)" >&2
                sleep $delay
                continue
            else
                echo "  ❌ API error after $max_retries attempts: $error_msg" >&2
                return 1
            fi
        fi
        
        # Check if response has expected structure
        local content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if [ -z "$content" ]; then
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                local delay=$((base_delay * (2 ** (retry_count - 1))))
                echo "  ⚠️  Empty response, retrying in ${delay}s... (attempt $retry_count/$max_retries)" >&2
                sleep $delay
                continue
            else
                echo "  ❌ Empty response after $max_retries attempts" >&2
                return 1
            fi
        fi
        
        # Success - return the response
        echo "$response"
        return 0
    done
    
    echo "  ❌ All retry attempts exhausted" >&2
    return 1
}

# Extract content from API response
# Usage: extract_content <api_response_json>
extract_content() {
    local response="$1"
    echo "$response" | jq -r '.choices[0].message.content // empty'
}

# Extract token usage from API response
# Usage: extract_usage <api_response_json>
# Returns: "input_tokens output_tokens"
extract_usage() {
    local response="$1"
    local input_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // 0')
    local output_tokens=$(echo "$response" | jq -r '.usage.completion_tokens // 0')
    echo "$input_tokens $output_tokens"
}

# Validate API key is available
# Usage: validate_api_key
validate_api_key() {
    if [ -z "${MOONSHOT_API_KEY:-}" ]; then
        load_api_key
    fi
    
    if [ -z "${MOONSHOT_API_KEY:-}" ]; then
        echo "❌ Moonshot API key not found"
        return 1
    fi
    
    echo "✅ API key loaded"
    return 0
}

# Export functions if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f load_api_key call_moonshot_api extract_content extract_usage validate_api_key
fi
