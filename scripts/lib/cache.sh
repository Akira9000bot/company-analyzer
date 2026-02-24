#!/bin/bash
#
# lib/cache.sh - Production-grade persistent caching for Hostinger VPS
#

# 1. Path Configuration
# Use Home directory to ensure full write permissions on restricted VPS hosts.
CACHE_ROOT="${HOME}/.openclaw/cache/company-analyzer"
CACHE_DIR="$CACHE_ROOT/responses"
CACHE_TTL_DAYS=7

# Initialize cache directory structure
init_cache() {
    mkdir -p "$CACHE_DIR"
}

# 2. Key Generation
# Usage: cache_key <ticker> <framework_id> <prompt_content>
cache_key() {
    local ticker="$1"
    local fw_id="$2"
    local prompt_content="$3"
    
    # We now hash the FULL prompt content to ensure the key is unique, 
    # even if prompts have long identical headers.
    local prompt_hash=$(echo -n "$prompt_content" | sha256sum | cut -d' ' -f1 | head -c 32)
    
    # Format: AAPL_01-phase_hash
    echo "${ticker}_${fw_id}_${prompt_hash}"
}

# 3. Cache Operations
# Usage: cache_get <cache_key>
cache_get() {
    local key="$1"
    local cache_file="$CACHE_DIR/${key}.json"
    
    if [ ! -f "$cache_file" ]; then
        return 1
    fi
    
    # Check if the cache entry has expired (7-day safety net)
    local age_days=$(cache_age "$key")
    if [ "$age_days" -gt "$CACHE_TTL_DAYS" ]; then
        # Silently expire to trigger a fresh (but paid) analysis
        rm -f "$cache_file"
        return 1
    fi
    
    # Return content only if jq can parse it (prevents corrupted cache reads)
    jq -r '.response // empty' "$cache_file" 2>/dev/null
}

# Usage: cache_set <cache_key> <response_content> <metadata_json>
cache_set() {
    local key="$1"
    local response="$2"
    local metadata="${3:-{}}"
    local cache_file="$CACHE_DIR/${key}.json"
    
    init_cache
    
    # Ensure metadata is valid JSON
    if ! echo "$metadata" | jq -e '.' >/dev/null 2>&1; then
        metadata="{}"
    fi
    
    # Use mktemp to prevent race conditions during parallel framework execution
    local temp_response=$(mktemp)
    printf '%s' "$response" > "$temp_response"
    
    # Atomically write to cache to prevent half-written files
    jq -n \
        --arg key "$key" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson metadata "$metadata" \
        --rawfile response "$temp_response" \
        '{
            cache_key: $key,
            response: $response,
            cached_at: $timestamp,
            metadata: $metadata
        }' > "$cache_file"
    
    local exit_code=$?
    rm -f "$temp_response"
    return $exit_code
}

# 4. Utility Functions
cache_age() {
    local key="$1"
    local cache_file="$CACHE_DIR/${key}.json"
    
    if [ ! -f "$cache_file" ]; then
        echo "999"
        return 0
    fi
    
    local file_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
    local now=$(date +%s)
    local age_days=$(( (now - file_time) / 86400 ))
    
    echo "$age_days"
}

cache_cleanup() {
    if [ -d "$CACHE_DIR" ]; then
        # Automatically purge files older than TTL to save VPS disk space
        find "$CACHE_DIR" -name "*.json" -type f -mtime +$CACHE_TTL_DAYS -delete 2>/dev/null
    fi
}

# Export for use in run-framework.sh and analyze-parallel.sh
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f init_cache cache_key cache_get cache_set cache_age cache_cleanup
fi