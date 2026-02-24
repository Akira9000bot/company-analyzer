#!/bin/bash
#
# fetch_data.sh - Enhanced data acquisition with Narrative Text Extraction
# Optimized for sequential pipeline and high-density analysis.
#

set -euo pipefail

# Source tracing library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/trace.sh"

TICKER="${1:-}"
[ -z "$TICKER" ] && { echo "Usage: ./fetch_data.sh <TICKER>"; exit 1; }

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')

# Cache location setup
FETCH_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$FETCH_SKILL_DIR/.cache/data"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"
SEC_FILE="$DATA_DIR/${TICKER_UPPER}_sec_raw.json"
AV_FILE="$DATA_DIR/${TICKER_UPPER}_av_raw.json"
QUOTE_FILE="$DATA_DIR/${TICKER_UPPER}_quote_raw.json"

mkdir -p "$DATA_DIR"

# Load Alpha Vantage API key
AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
ALPHA_VANTAGE_KEY=""
if [ -f "$AUTH_PROFILES" ]; then
    ALPHA_VANTAGE_KEY=$(jq -r '.profiles["alpha-vantage:default"].key // .profiles["alphavantage:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")
fi

# 1-day cache check
if [ -f "$DATA_FILE" ]; then
    AGE_HOURS=$(( ( $(date +%s) - $(stat -c %Y "$DATA_FILE" 2>/dev/null || echo 0) ) / 3600 ))
    if [ $AGE_HOURS -lt 24 ]; then
        echo "✅ Using cached data (${AGE_HOURS}h old)"
        exit 0
    fi
fi

echo "📊 Fetching data for $TICKER_UPPER..."
init_trace
USER_AGENT="akira9000bot@gmail.com"

# ============================================
# Alpha Vantage - Price and Valuation Data
# ============================================
fetch_alpha_vantage() {
    log_trace "INFO" "FETCH" "Attempting Alpha Vantage fetch"
    if [ -z "$ALPHA_VANTAGE_KEY" ]; then
        log_trace "WARN" "FETCH" "Alpha Vantage key not found"
        return 1
    fi
    
    echo "  🔍 Fetching Alpha Vantage data..."
    
    # 1. Get quote data (for real-time price)
    local quote_response=$(curl -s --max-time 15 \
        "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=${TICKER_UPPER}&apikey=${ALPHA_VANTAGE_KEY}")
    
    echo "$quote_response" > "$QUOTE_FILE"

    if echo "$quote_response" | grep -q "Thank you for using Alpha Vantage"; then
        log_trace "WARN" "FETCH" "Alpha Vantage rate limit reached"
        return 1
    fi

    echo "  ⏳ Respecting API rate limits (12s pause)..."
    sleep 12
    
    # 2. Get overview data (for P/E, Market Cap, description)
    local overview_response=$(curl -s --max-time 15 \
        "https://www.alphavantage.co/query?function=OVERVIEW&symbol=${TICKER_UPPER}&apikey=${ALPHA_VANTAGE_KEY}")
    
    echo "$overview_response" > "$AV_FILE"
    
    if echo "$overview_response" | jq -e '.Symbol' > /dev/null 2>&1; then
        echo "  ✅ Alpha Vantage data retrieved"
        return 0
    else
        return 1
    fi
}

# ============================================
# SEC Metadata & CIK Lookup
# ============================================
fetch_sec_cik() {
    echo "  🔍 Looking up SEC CIK..."
    local cik_lookup=$(curl -s --max-time 15 \
        -H "User-Agent: $USER_AGENT" \
        "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}&type=10-K&output=atom" 2>/dev/null || echo "")
    
    CIK=$(echo "$cik_lookup" | grep -o '<cik>[^<]*' | head -1 | sed 's/<cik>//' || echo "")
    if [ -z "$CIK" ]; then return 1; fi
    echo "  ✅ Found CIK: $CIK"
    return 0
}

fetch_sec_facts() {
    echo "  🔍 Fetching company facts from SEC..."
    local cik_padded=$(printf "%010d" "$(echo "$CIK" | sed 's/^0*//')" 2>/dev/null)
    curl -s --max-time 30 -H "User-Agent: $USER_AGENT" \
        "https://data.sec.gov/api/xbrl/companyfacts/CIK${cik_padded}.json" -o "$SEC_FILE" 2>/dev/null || return 1
    return 0
}

# ============================================
# NEW: Narrative Text Extraction Logic
# ============================================
fetch_sec_text() {
    echo "  🔍 Extracting narrative text from latest filing..."
    local cik_padded=$(printf "%010d" "$(echo "$CIK" | sed 's/^0*//')")
    local sub_json=$(curl -s -H "User-Agent: $USER_AGENT" "https://data.sec.gov/submissions/CIK${cik_padded}.json")
    
    # Find latest 10-K or 10-Q index
    local idx=$(echo "$sub_json" | jq -r '.filings.recent.form | to_entries | .[] | select(.value == "10-K" or .value == "10-Q") | .key' | head -1)
    
    if [ -z "$idx" ] || [ "$idx" == "null" ]; then
        ITEM1_TEXT="N/A"; ITEM1A_TEXT="N/A"; return 1
    fi
    
    local acc_no=$(echo "$sub_json" | jq -r ".filings.recent.accessionNumber[$idx]")
    local primary_doc=$(echo "$sub_json" | jq -r ".filings.recent.primaryDocument[$idx]")
    local acc_no_clean=$(echo "$acc_no" | tr -d '-')
    local filing_url="https://www.sec.gov/Archives/edgar/data/${CIK}/${acc_no_clean}/${primary_doc}"
    
    echo "  📂 Downloading: $primary_doc"
    local raw_html=$(curl -s -H "User-Agent: $USER_AGENT" "$filing_url")
    
    # Advanced stripping: Removes HTML tags and simplifies whitespace
    local clean_text=$(echo "$raw_html" | sed 's/<[^>]*>/ /g' | tr -s ' ' | tr -d '\r')
    
    # Extract using more flexible Case-Insensitive regex
    ITEM1_TEXT=$(echo "$clean_text" | grep -iP "Item 1\.(Business|Overview).*?Item 1A\." -o | head -c 35000 || echo "N/A")
    ITEM1A_TEXT=$(echo "$clean_text" | grep -iP "Item 1A\.(Risk Factors).*?Item (1B|2)\." -o | head -c 35000 || echo "N/A")

    # Final cleanup of extraction artifacts
    ITEM1_TEXT=$(echo "$ITEM1_TEXT" | sed 's/Item 1A\..*//I')
    ITEM1A_TEXT=$(echo "$ITEM1A_TEXT" | sed 's/Item \(1B\|2\)\..*//I')

    echo "  ✅ Narrative text enriched (Length: $((${#ITEM1_TEXT} + ${#ITEM1A_TEXT})) chars)."
}

# ============================================
# Helper: Data Extraction
# ============================================
extract_sec_value() {
    local file="$1"; local unit="${2:-USD}"; shift 2
    for tag in "$@"; do
        local val=$(jq -r ".facts.\"us-gaap\"[\"$tag\"].units[\"$unit\"] | sort_by(.end) | last | .val // empty" "$file" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" != "null" ]; then echo "$val"; return 0; fi
    done
    echo "N/A"
}

extract_av_value() {
    local file="$1"; local field="$2"
    local val=$(jq -r ".${field} // empty" "$file" 2>/dev/null)
    [ -n "$val" ] && [ "$val" != "None" ] && echo "$val" || echo "N/A"
}

# ============================================
# Main Execution Sequence
# ============================================
AV_SUCCESS=false
fetch_alpha_vantage && AV_SUCCESS=true || echo "  ⚠️ Alpha Vantage failed, skipping market data."

fetch_sec_cik || { echo "❌ Could not find SEC CIK"; exit 1; }
fetch_sec_facts || echo "⚠️ Failed to fetch numeric facts."
fetch_sec_text || echo "⚠️ Failed to fetch narrative text."

# Extract Metrics
echo "  💾 Compiling Final Dataset..."
COMPANY_NAME=$(jq -r '.entityName // "N/A"' "$SEC_FILE" 2>/dev/null || echo "N/A")
REVENUE=$(extract_sec_value "$SEC_FILE" "USD" "Revenues" "SalesRevenueNet")
NET_INCOME=$(extract_sec_value "$SEC_FILE" "USD" "NetIncomeLoss" "ProfitLoss")
CURRENT_PRICE=$(jq -r '.["Global Quote"]["05. price"] // "N/A"' "$QUOTE_FILE" 2>/dev/null)
MARKET_CAP=$(extract_av_value "$AV_FILE" "MarketCapitalization")
PE_RATIO=$(extract_av_value "$AV_FILE" "PERatio")

# Build Enriched JSON
jq -n \
    --arg ticker "$TICKER_UPPER" \
    --arg cik "$CIK" \
    --arg name "$COMPANY_NAME" \
    --arg rev "$REVENUE" \
    --arg ni "$NET_INCOME" \
    --arg price "$CURRENT_PRICE" \
    --arg cap "$MARKET_CAP" \
    --arg pe "$PE_RATIO" \
    --arg item1 "${ITEM1_TEXT:-N/A}" \
    --arg item1a "${ITEM1A_TEXT:-N/A}" \
    '{
        ticker: $ticker,
        cik: $cik,
        timestamp: ("" + (now | strftime("%Y-%m-%dT%H:%M:%SZ"))),
        company_profile: { name: $name },
        financial_metrics: { revenue: $rev, net_income: $ni },
        valuation: { current_price: $price, market_cap: $cap, pe_ratio: $pe },
        sec_data: { item1: $item1, item1a: $item1a }
    }' > "$DATA_FILE"

# Final Cleanup of raw quote file
rm -f "$QUOTE_FILE"
echo "✅ Enriched data saved: $DATA_FILE"