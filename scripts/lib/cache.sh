#!/bin/bash
#
# lib/cache.sh - Response caching utilities
# Cache location: <skill_dir>/.cache/responses/
#

# Get skill root directory (2 levels up from lib/)
CACHE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_SKILL_DIR="$(cd "$CACHE_LIB_DIR/../.." && pwd)"
CACHE_DIR="$CACHE_SKILL_DIR/.cache/responses"
CACHE_TTL_DAYS=7

# Initialize cache directory
init_cache() {
    mkdir -p "$CACHE_DIR"
}

# Generate cache key from ticker, framework, and prompt content
# Usage: cache_key <ticker> <framework_id> <prompt_content>
cache_key() {
    local ticker="$1"
    local fw_id="$2"
    local prompt_content="$3"
    
    # Create hash from prompt content (first 500 chars for efficiency)
    local prompt_hash=$(echo "${prompt_content:0:500}" | sha256sum | cut -d' ' -f1 | head -c 16)
    
    # Combine ticker, framework, and prompt hash
    echo "${ticker}_${fw_id}_${prompt_hash}"
}

# Get cached response if it exists and is not expired
# Usage: cache_get <cache_key>
# Returns: cached content or empty string
cache_get() {
    local key="$1"
    local cache_file="$CACHE_DIR/${key}.json"
    
    if [ ! -f "$cache_file" ]; then
        echo ""
        return 1
    fi
    
    # Check if expired
    local age_days=$(cache_age "$key")
    if [ "$age_days" -gt "$CACHE_TTL_DAYS" ]; then
        echo ""
        return 1
    fi
    
    # Return cached content
    jq -r '.response // empty' "$cache_file" 2>/dev/null
}

# Store response in cache
# Usage: cache_set <cache_key> <response_content> <metadata_json>
cache_set() {
    local key="$1"
    local response="$2"
    local metadata="${3:-{}}"
    local cache_file="$CACHE_DIR/${key}.json"
    
    init_cache
    
    # Validate metadata is valid JSON, fallback to empty object
    if ! echo "$metadata" | jq -e '.' >/dev/null 2>&1; then
        metadata="{}"
    fi
    
    # Write response to temp file first (handles special chars safely)
    local temp_response=$(mktemp)
    printf '%s' "$response" > "$temp_response"
    
    # Build cache entry using jq --rawfile for the response content
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

# Get cache age in days
# Usage: cache_age <cache_key>
# Returns: age in days (0 if not found)
cache_age() {
    local key="$1"
    local cache_file="$CACHE_DIR/${key}.json"
    
    if [ ! -f "$cache_file" ]; then
        echo "999"
        return 1
    fi
    
    local file_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
    local now=$(date +%s)
    local age_seconds=$((now - file_time))
    local age_days=$((age_seconds / 86400))
    
    echo "$age_days"
}

# Get cache metadata
# Usage: cache_metadata <cache_key>
cache_metadata() {
    local key="$1"
    local cache_file="$CACHE_DIR/${key}.json"
    
    if [ ! -f "$cache_file" ]; then
        echo "{}"
        return 1
    fi
    
    jq -r '.metadata // {}' "$cache_file"
}

# Clean expired cache entries
cache_cleanup() {
    if [ ! -d "$CACHE_DIR" ]; then
        return 0
    fi
    
    find "$CACHE_DIR" -name "*.json" -type f -mtime +$CACHE_TTL_DAYS -delete 2>/dev/null
    echo "Cache cleanup complete"
}

# Get cache stats
cache_stats() {
    init_cache
    
    local total_files=$(find "$CACHE_DIR" -name "*.json" -type f 2>/dev/null | wc -l)
    local total_size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
    
    echo "Cache Statistics:"
    echo "  Location: $CACHE_DIR"
    echo "  Entries: $total_files"
    echo "  Size: $total_size"
    echo "  TTL: $CACHE_TTL_DAYS days"
}

# Export functions if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f init_cache cache_key cache_get cache_set cache_age cache_metadata cache_cleanup cache_stats
fi
