#!/bin/bash
#
# fetch_data.sh - Enhanced data acquisition with Narrative Text Extraction
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
        echo "  ⚠️  Alpha Vantage API key not found, skipping"
        return 1
    fi
    
    echo "  🔍 Fetching Alpha Vantage data..."
    
    # 1. Get quote data
    local start_time=$(date +%s.%N)
    local quote_response=$(curl -s --max-time 15 \
        "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=${TICKER_UPPER}&apikey=${ALPHA_VANTAGE_KEY}" 2>/dev/null)
    local end_time=$(date +%s.%N)
    local latency=$(echo "$end_time - $start_time" | bc)
    
    log_trace "INFO" "FETCH" "Alpha Vantage quote | Latency: ${latency}s"
    
    # SAFETY: Check for the Alpha Vantage "Note" (Rate Limit Message)
    if echo "$quote_response" | grep -q "Thank you for using Alpha Vantage"; then
        log_trace "WARN" "FETCH" "Alpha Vantage rate limit reached"
        echo "  ❌ Alpha Vantage Limit Reached (Daily or Minute). Skipping price data."
        return 1
    fi

    # SAFETY: Mandatory 12-second sleep to stay under the 5-per-minute limit
    echo "  ⏳ Respecting API rate limits (12s pause)..."
    sleep 12
    
    # 2. Get overview data (contains P/E, market cap, etc.)
    local overview_response=$(curl -s --max-time 15 \
        "https://www.alphavantage.co/query?function=OVERVIEW&symbol=${TICKER_UPPER}&apikey=${ALPHA_VANTAGE_KEY}" 2>/dev/null)
    
    # Save raw responses
    echo "$overview_response" > "$AV_FILE"
    
    # Check if we got valid data
    if echo "$overview_response" | jq -e '.Symbol' > /dev/null 2>&1; then
        echo "  ✅ Alpha Vantage data retrieved"
        return 0
    else
        echo "  ⚠️  Alpha Vantage rate limit or invalid response"
        return 1
    fi
}

# ============================================
# Get CIK from SEC
# ============================================
fetch_sec_cik() {
    log_trace "INFO" "FETCH" "Looking up SEC CIK"
    echo "  🔍 Looking up SEC CIK..."
    
    local start_time=$(date +%s.%N)
    local cik_lookup=$(curl -s --max-time 15 \
        -H "User-Agent: $USER_AGENT" \
        "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}&type=10-K&dateb=&owner=include&count=1&output=atom" 2>/dev/null || echo "")
    local end_time=$(date +%s.%N)
    local latency=$(echo "$end_time - $start_time" | bc)
    
    log_trace "INFO" "FETCH" "SEC CIK lookup | Latency: ${latency}s"
    CIK=$(echo "$cik_lookup" | grep -o '<cik>[^<]*' | head -1 | sed 's/<cik>//' || echo "")
    
    if [ -z "$CIK" ]; then
        echo "  ❌ Could not find CIK for $TICKER_UPPER"
        return 1
    fi
    
    echo "  ✅ Found CIK: $CIK"
    return 0
}

# ============================================
# Fetch company facts from SEC
# ============================================
fetch_sec_facts() {
    echo "  🔍 Fetching company facts from SEC..."
    
    # CIK may already be padded; if not, pad it to 10 digits
    if [ ${#CIK} -eq 10 ]; then
        CIK_PADDED="$CIK"
    else
        CIK_PADDED=$(printf "%010d" "$CIK" 2>/dev/null || echo "$CIK")
    fi
    
    # Save SEC data to temp file first
    curl -s --max-time 30 \
        -H "User-Agent: $USER_AGENT" \
        "https://data.sec.gov/api/xbrl/companyfacts/CIK${CIK_PADDED}.json" \
        -o "$SEC_FILE" 2>/dev/null || true
    
    # Check if we got valid data
    if [ ! -f "$SEC_FILE" ] || [ ! -s "$SEC_FILE" ]; then
        echo "  ❌ Failed to fetch SEC data"
        return 1
    fi
    
    # Validate JSON
    if ! jq -e '.' "$SEC_FILE" > /dev/null 2>&1; then
        echo "  ❌ Invalid JSON received from SEC"
        rm -f "$SEC_FILE"
        return 1
    fi
    
    echo "  ✅ SEC data retrieved"
    return 0
}

# ============================================
# Extract SEC financial data
# ============================================
extract_sec_value() {
    local file="$1"
    local unit="${2:-USD}"
    shift 2
    
    for tag in "$@"; do
        local val=$(jq -r ".facts.\"us-gaap\"[\"$tag\"].units[\"$unit\"] | sort_by(.end) | last | .val // empty" "$file" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" != "null" ] && [ "$val" != "" ]; then
            echo "$val"
            return 0
        fi
    done
    echo "N/A"
}

# ============================================
# Extract Alpha Vantage data
# ============================================
extract_av_value() {
    local file="$1"
    local field="$2"
    
    local val=$(jq -r ".${field} // empty" "$file" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ] && [ "$val" != "" ] && [ "$val" != "None" ]; then
        echo "$val"
        return 0
    fi
    echo "N/A"
}

# ============================================
# Extract Yahoo Finance data fallback
# ============================================
fetch_yahoo_finance_fallback() {
    echo "  🔍 Fetching fallback price from Yahoo Finance..."
    
    # Use the v8 chart endpoint for the most reliable public data in 2026
    local yf_response=$(curl -s --max-time 10 \
        "https://query1.finance.yahoo.com/v8/finance/chart/${TICKER_UPPER}?interval=1d&range=1d" 2>/dev/null)
    
    # Extract regularMarketPrice using jq
    local price=$(echo "$yf_response" | jq -r '.chart.result[0].meta.regularMarketPrice // empty' 2>/dev/null)
    
    if [ -n "$price" ] && [ "$price" != "null" ]; then
        # We simulate a "minimal" AV raw file so your extraction functions don't crash
        echo "{\"Symbol\": \"${TICKER_UPPER}\", \"Note\": \"Fallback data from Yahoo\"}" > "$AV_FILE"
        CURRENT_PRICE=$price
        echo "  ✅ Fallback Price Found: \$$price"
        return 0
    else
        echo "  ⚠️  Yahoo Finance fallback also failed."
        return 1
    fi
}

# ============================================
# NEW: Fetch narrative text (10-K/10-Q)
# ============================================
fetch_sec_text() {
    echo "  🔍 Fetching narrative text from SEC EDGAR..."
    
    # CIK may have leading zeros (bash treats as octal). Strip them for printf.
    local clean_cik=$(echo "$CIK" | sed 's/^0*//')
    [ -z "$clean_cik" ] && clean_cik=0
    local cik_padded=$(printf "%010d" "$clean_cik")
    local submissions_url="https://data.sec.gov/submissions/CIK${cik_padded}.json"
    local submissions_json=$(curl -s -H "User-Agent: $USER_AGENT" "$submissions_url")
    
    # 1. Find the index of the latest 10-K or 10-Q filing
    local idx=$(echo "$submissions_json" | jq -r '.filings.recent.form | to_entries | .[] | select(.value == "10-K" or .value == "10-Q") | .key' | head -1)
    
    if [ -z "$idx" ] || [ "$idx" == "null" ]; then
        echo "  ⚠️  No 10-K or 10-Q found in recent submissions."
        ITEM1_TEXT="N/A"
        ITEM1A_TEXT="N/A"
        return 1
    fi
    
    # 2. Construct the URL for the primary document
    local acc_no=$(echo "$submissions_json" | jq -r ".filings.recent.accessionNumber[$idx]")
    local primary_doc=$(echo "$submissions_json" | jq -r ".filings.recent.primaryDocument[$idx]")
    local acc_no_clean=$(echo "$acc_no" | tr -d '-')
    local filing_url="https://www.sec.gov/Archives/edgar/data/${CIK}/${acc_no_clean}/${primary_doc}"
    
    echo "  📂 Downloading Filing: $filing_url"
    
    # 3. Download and strip HTML tags to get clean text
    local raw_html=$(curl -s -H "User-Agent: $USER_AGENT" "$filing_url")
    local clean_text=$(echo "$raw_html" | sed 's/<[^>]*>/ /g' | tr -s ' ' | tr -d '\r')
    
    # 4. Use markers to isolate Item 1 and Item 1A (approximate bounds)
    ITEM1_TEXT=$(echo "$clean_text" | grep -iP "Item 1\..*?Item 1A\." -o | head -c 35000 || echo "N/A")
    ITEM1A_TEXT=$(echo "$clean_text" | grep -iP "Item 1A\..*?Item 1B\.|Item 2\." -o | head -c 35000 || echo "N/A")

    echo "  ✅ Narrative text extracted (Item 1: ${#ITEM1_TEXT} chars, Item 1A: ${#ITEM1A_TEXT} chars)."
}

# ============================================
# Execution Flow
# ============================================
# Priority 1: Market Data
AV_SUCCESS=false
if fetch_alpha_vantage; then
    AV_SUCCESS=true
else
    echo "  ⚠️  Alpha Vantage failed or limited. Trying Yahoo Finance fallback..."
    if fetch_yahoo_finance_fallback; then
        AV_SUCCESS=true
    else
        echo "  ❌ All valuation sources failed. Proceeding with SEC data only."
    fi
fi

# Priority 2: SEC Numeric and Narrative Data
if ! fetch_sec_cik; then
    echo "  ❌ Cannot proceed without SEC CIK"
    exit 1
fi

if ! fetch_sec_facts; then
    echo "  ❌ Cannot proceed without SEC data"
    exit 1
fi

fetch_sec_text # <--- NEW CALL

# ============================================
# Extract all data
# ============================================
echo "  🔍 Extracting financial metrics..."

# Get company name from SEC data
COMPANY_NAME=$(jq -r '.entityName // "N/A"' "$SEC_FILE")

# SEC financial metrics
REVENUE=$(extract_sec_value "$SEC_FILE" "USD" "Revenues" "RevenueFromContractWithCustomerExcludingAssessedTax" "SalesRevenueNet")
NET_INCOME=$(extract_sec_value "$SEC_FILE" "USD" "NetIncomeLoss" "ProfitLoss")
TOTAL_ASSETS=$(extract_sec_value "$SEC_FILE" "USD" "Assets")
TOTAL_LIABILITIES=$(extract_sec_value "$SEC_FILE" "USD" "Liabilities")
STOCKHOLDERS_EQUITY=$(extract_sec_value "$SEC_FILE" "USD" "StockholdersEquity")
OPERATING_INCOME=$(extract_sec_value "$SEC_FILE" "USD" "OperatingIncomeLoss")
SHARES_OUTSTANDING=$(extract_sec_value "$SEC_FILE" "shares" "CommonStockSharesOutstanding" "CommonStockSharesIssued")

# Alpha Vantage valuation data
if [ "$AV_SUCCESS" = true ] && [ -f "$AV_FILE" ]; then
    MARKET_CAP=$(extract_av_value "$AV_FILE" "MarketCapitalization")
    PE_RATIO=$(extract_av_value "$AV_FILE" "PERatio")
    FORWARD_PE=$(extract_av_value "$AV_FILE" "ForwardPE")
    EPS=$(extract_av_value "$AV_FILE" "EPS")
    DIVIDEND_YIELD=$(extract_av_value "$AV_FILE" "DividendYield")
    FIFTY_TWO_WEEK_HIGH=$(extract_av_value "$AV_FILE" "52WeekHigh")
    FIFTY_TWO_WEEK_LOW=$(extract_av_value "$AV_FILE" "52WeekLow")
    
    # Ensure current price is set if coming from AV directly
    if [ -z "${CURRENT_PRICE:-}" ]; then
        CURRENT_PRICE=$(extract_av_value "$AV_FILE" "CurrentPrice" || echo "N/A")
    fi
else
    CURRENT_PRICE="${CURRENT_PRICE:-N/A}"
    MARKET_CAP="N/A"
    PE_RATIO="N/A"
    FORWARD_PE="N/A"
    EPS="N/A"
    DIVIDEND_YIELD="N/A"
    FIFTY_TWO_WEEK_HIGH="N/A"
    FIFTY_TWO_WEEK_LOW="N/A"
fi

# ============================================
# Cleanup temp files
# ============================================
rm -f "$SEC_FILE"

# ============================================
# Build JSON output
# ============================================
echo "  💾 Saving enriched data..."

jq -n \
    --arg ticker "$TICKER_UPPER" \
    --arg cik "$CIK" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg name "$COMPANY_NAME" \
    --arg rev "$REVENUE" \
    --arg ni "$NET_INCOME" \
    --arg assets "$TOTAL_ASSETS" \
    --arg liab "$TOTAL_LIABILITIES" \
    --arg equity "$STOCKHOLDERS_EQUITY" \
    --arg op_inc "$OPERATING_INCOME" \
    --arg shares "$SHARES_OUTSTANDING" \
    --arg price "$CURRENT_PRICE" \
    --arg cap "$MARKET_CAP" \
    --arg pe "$PE_RATIO" \
    --arg item1 "$ITEM1_TEXT" \
    --arg item1a "$ITEM1A_TEXT" \
    '{
        ticker: $ticker,
        cik: $cik,
        timestamp: $timestamp,
        company_profile: { name: $name },
        financial_metrics: {
            revenue: $rev,
            net_income: $ni,
            total_assets: $assets,
            total_liabilities: $liab,
            stockholders_equity: $equity,
            operating_income: $op_inc,
            shares_outstanding: $shares
        },
        valuation: { current_price: $price, market_cap: $cap, pe_ratio: $pe },
        sec_data: {
            item1: $item1,
            item1a: $item1a
        }
    }' > "$DATA_FILE"

echo "✅ Finished: $DATA_FILE"
