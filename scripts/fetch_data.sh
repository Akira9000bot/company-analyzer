#!/bin/bash
#
# fetch_data.sh - Free data acquisition with Alpha Vantage + SEC EDGAR fallback
# Fetches real financial data for company analysis
#
# Priority:
#   1. Alpha Vantage (free tier: 25 calls/day) - for price data (market cap, P/E)
#   2. SEC EDGAR API - for financial metrics
#

set -euo pipefail

# Source tracing library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/trace.sh"

TICKER="${1:-}"
[ -z "$TICKER" ] && { echo "Usage: ./fetch_data.sh <TICKER>"; exit 1; }

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
DATA_DIR="/tmp/company-analyzer-cache"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"
SEC_FILE="$DATA_DIR/${TICKER_UPPER}_sec_raw.json"
AV_FILE="$DATA_DIR/${TICKER_UPPER}_av_raw.json"

mkdir -p "$DATA_DIR"

# Load Alpha Vantage API key from auth profiles
AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
ALPHA_VANTAGE_KEY=""
if [ -f "$AUTH_PROFILES" ]; then
    ALPHA_VANTAGE_KEY=$(jq -r '.profiles["alpha-vantage:default"].key // .profiles["alphavantage:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")
fi

# Check if data already exists (1-day cache for fresh data)
if [ -f "$DATA_FILE" ]; then
    AGE_HOURS=$(( ( $(date +%s) - $(stat -c %Y "$DATA_FILE" 2>/dev/null || echo 0) ) / 3600 ))
    if [ $AGE_HOURS -lt 24 ]; then
        echo "✅ Using cached data (${AGE_HOURS}h old)"
        echo "   $DATA_FILE"
        exit 0
    fi
fi

# Source tracing library
source "$(dirname "${BASH_SOURCE[0]}")/lib/trace.sh"

echo "📊 Fetching data for $TICKER_UPPER..."
log_trace "INFO" "FETCH" "Starting data fetch for $TICKER_UPPER"

# Initialize trace
init_trace
log_trace "INFO" "FETCH" "Starting data fetch for $TICKER_UPPER"

# Set a user agent as required by SEC
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
# Main data fetching
# ============================================

# Priority 1: Alpha Vantage (Valuation & Price)
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

# Priority 2: SEC EDGAR (Always required for Financial DNA)
if ! fetch_sec_cik; then
    echo "  ❌ Cannot proceed without SEC CIK"
    exit 1
fi

if ! fetch_sec_facts; then
    echo "  ❌ Cannot proceed without SEC data"
    exit 1
fi

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
    CURRENT_PRICE=$(extract_av_value "$AV_FILE" "MarketCapitalization" | awk '{print $1/1000000000}')
    if [ "$CURRENT_PRICE" != "N/A" ]; then
        # We got market cap, now get actual price
        CURRENT_PRICE=$(curl -s --max-time 10 \
            "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=${TICKER_UPPER}&apikey=${ALPHA_VANTAGE_KEY}" 2>/dev/null | \
            jq -r '.["Global Quote"]["05. price"] // "N/A"')
    fi
    
    MARKET_CAP=$(extract_av_value "$AV_FILE" "MarketCapitalization")
    PE_RATIO=$(extract_av_value "$AV_FILE" "PERatio")
    FORWARD_PE=$(extract_av_value "$AV_FILE" "ForwardPE")
    EPS=$(extract_av_value "$AV_FILE" "EPS")
    DIVIDEND_YIELD=$(extract_av_value "$AV_FILE" "DividendYield")
    FIFTY_TWO_WEEK_HIGH=$(extract_av_value "$AV_FILE" "52WeekHigh")
    FIFTY_TWO_WEEK_LOW=$(extract_av_value "$AV_FILE" "52WeekLow")
else
    CURRENT_PRICE="N/A"
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
echo "  💾 Saving data..."

jq -n \
    --arg ticker "$TICKER_UPPER" \
    --arg cik "$CIK" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg company_name "$COMPANY_NAME" \
    --arg revenue "$REVENUE" \
    --arg net_income "$NET_INCOME" \
    --arg total_assets "$TOTAL_ASSETS" \
    --arg total_liabilities "$TOTAL_LIABILITIES" \
    --arg stockholders_equity "$STOCKHOLDERS_EQUITY" \
    --arg operating_income "$OPERATING_INCOME" \
    --arg shares_outstanding "$SHARES_OUTSTANDING" \
    --arg current_price "$CURRENT_PRICE" \
    --arg market_cap "$MARKET_CAP" \
    --arg pe_ratio "$PE_RATIO" \
    --arg forward_pe "$FORWARD_PE" \
    --arg eps "$EPS" \
    --arg dividend_yield "$DIVIDEND_YIELD" \
    --arg fifty_two_week_high "$FIFTY_TWO_WEEK_HIGH" \
    --arg fifty_two_week_low "$FIFTY_TWO_WEEK_LOW" \
    --arg av_success "$AV_SUCCESS" \
    '{
        ticker: $ticker,
        cik: $cik,
        timestamp: $timestamp,
        company_profile: {
            name: $company_name
        },
        financial_metrics: {
            revenue: $revenue,
            net_income: $net_income,
            total_assets: $total_assets,
            total_liabilities: $total_liabilities,
            stockholders_equity: $stockholders_equity,
            operating_income: $operating_income,
            shares_outstanding: $shares_outstanding
        },
        valuation: {
            current_price: $current_price,
            market_cap: $market_cap,
            pe_ratio: $pe_ratio,
            forward_pe: $forward_pe,
            eps: $eps,
            dividend_yield: $dividend_yield,
            fifty_two_week_high: $fifty_two_week_high,
            fifty_two_week_low: $fifty_two_week_low
        },
        data_sources: {
            sec_edgar: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=\($ticker)",
            alpha_vantage: (if $av_success == "true" then "success" else "not_available" end)
        },
        notes: (if $av_success == "true" 
            then "Financial data from SEC EDGAR. Price/valuation data from Alpha Vantage." 
            else "Financial data from SEC EDGAR only. Alpha Vantage unavailable (no API key or rate limit)."
        end)
    }' > "$DATA_FILE"

# Display results
echo ""
echo "✅ Data fetched successfully for $TICKER_UPPER"
echo "   File: $DATA_FILE"
echo ""

if [ "$REVENUE" != "N/A" ]; then
    echo "📊 Financial Data (from SEC):"
    [ "$COMPANY_NAME" != "N/A" ] && echo "   Company: $COMPANY_NAME"
    echo "   Revenue: $REVENUE"
    [ "$NET_INCOME" != "N/A" ] && echo "   Net Income: $NET_INCOME"
    [ "$TOTAL_ASSETS" != "N/A" ] && echo "   Total Assets: $TOTAL_ASSETS"
    [ "$OPERATING_INCOME" != "N/A" ] && echo "   Operating Income: $OPERATING_INCOME"
    echo ""
fi

if [ "$AV_SUCCESS" = true ]; then
    echo "💰 Valuation Data (from Alpha Vantage):"
    [ "$CURRENT_PRICE" != "N/A" ] && echo "   Current Price: \$$CURRENT_PRICE"
    [ "$MARKET_CAP" != "N/A" ] && echo "   Market Cap: $MARKET_CAP"
    [ "$PE_RATIO" != "N/A" ] && echo "   P/E Ratio: $PE_RATIO"
    [ "$FORWARD_PE" != "N/A" ] && echo "   Forward P/E: $FORWARD_PE"
    echo ""
else
    echo "⚠️  Price/valuation data unavailable (Alpha Vantage not configured or rate limited)"
    echo "   Analysis will use SEC financial data only."
    echo ""
fi

echo "   Ready to run: ./analyze-parallel.sh $TICKER_UPPER --live"
