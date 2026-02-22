#!/bin/bash
#
# fetch_data.sh - Free data acquisition (SEC EDGAR API primary)
# Fetches real financial data for company analysis
#
# Note: Yahoo Finance now requires authentication. 
# Price data may be incomplete - analysis focuses on SEC financial metrics.
#

set -euo pipefail

TICKER="${1:-}"
[ -z "$TICKER" ] && { echo "Usage: ./fetch_data.sh <TICKER>"; exit 1; }

TICKER_UPPER=$(echo "$TICKER" | tr '[:lower:]' '[:upper:]')
DATA_DIR="/tmp/company-analyzer-cache"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"
SEC_FILE="$DATA_DIR/${TICKER_UPPER}_sec_raw.json"

mkdir -p "$DATA_DIR"

# Check if data already exists (1-day cache for fresh data)
if [ -f "$DATA_FILE" ]; then
    AGE_HOURS=$(( ( $(date +%s) - $(stat -c %Y "$DATA_FILE" 2>/dev/null || echo 0) ) / 3600 ))
    if [ $AGE_HOURS -lt 24 ]; then
        echo "✅ Using cached data (${AGE_HOURS}h old)"
        echo "   $DATA_FILE"
        exit 0
    fi
fi

echo "📊 Fetching data for $TICKER_UPPER..."

# Set a user agent as required by SEC
USER_AGENT="OpenClaw Research (user@example.com)"

# ============================================
# Get CIK from SEC
# ============================================
echo "  🔍 Looking up SEC CIK..."
CIK_LOOKUP=$(curl -s --max-time 15 \
    -H "User-Agent: $USER_AGENT" \
    "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}&type=10-K&dateb=&owner=include&count=1&output=atom" 2>/dev/null || echo "")

CIK=$(echo "$CIK_LOOKUP" | grep -o '<cik>[^<]*' | head -1 | sed 's/<cik>//' || echo "")

if [ -z "$CIK" ]; then
    echo "  ❌ Could not find CIK for $TICKER_UPPER"
    echo "   The ticker may be invalid or the company doesn't file with SEC."
    exit 1
fi

echo "  ✅ Found CIK: $CIK"

# ============================================
# Fetch company facts from SEC
# ============================================
echo "  🔍 Fetching company facts from SEC..."
CIK_PADDED=$(printf "%010d" "$CIK" 2>/dev/null || echo "$CIK")

# Save SEC data to temp file first
curl -s --max-time 30 \
    -H "User-Agent: $USER_AGENT" \
    "https://data.sec.gov/api/xbrl/companyfacts/CIK${CIK_PADDED}.json" \
    -o "$SEC_FILE" 2>/dev/null || true

# Check if we got valid data
if [ ! -f "$SEC_FILE" ] || [ ! -s "$SEC_FILE" ]; then
    echo "  ❌ Failed to fetch SEC data"
    exit 1
fi

# Validate JSON
if ! jq -e '.' "$SEC_FILE" > /dev/null 2>&1; then
    echo "  ❌ Invalid JSON received from SEC"
    rm -f "$SEC_FILE"
    exit 1
fi

# ============================================
# Extract SEC financial data
# ============================================

echo "  🔍 Extracting financial metrics..."

# Helper function to extract values from SEC data file
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

# Get company name from SEC data
COMPANY_NAME=$(jq -r '.entityName // "N/A"' "$SEC_FILE")

# Key financial metrics
REVENUE=$(extract_sec_value "$SEC_FILE" "USD" "Revenues" "RevenueFromContractWithCustomerExcludingAssessedTax" "SalesRevenueNet")
NET_INCOME=$(extract_sec_value "$SEC_FILE" "USD" "NetIncomeLoss" "ProfitLoss")
TOTAL_ASSETS=$(extract_sec_value "$SEC_FILE" "USD" "Assets")
TOTAL_LIABILITIES=$(extract_sec_value "$SEC_FILE" "USD" "Liabilities")
STOCKHOLDERS_EQUITY=$(extract_sec_value "$SEC_FILE" "USD" "StockholdersEquity")
OPERATING_INCOME=$(extract_sec_value "$SEC_FILE" "USD" "OperatingIncomeLoss")

# Get shares outstanding
SHARES_OUTSTANDING=$(extract_sec_value "$SEC_FILE" "shares" "CommonStockSharesOutstanding" "CommonStockSharesIssued")

# ============================================
# Cleanup temp file
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
    --arg current_price "N/A" \
    --arg market_cap "N/A" \
    --arg pe_ratio "N/A" \
    --arg forward_pe "N/A" \
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
            forward_pe: $forward_pe
        },
        data_sources: {
            sec_edgar: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=\($ticker)"
        },
        notes: "Financial data from SEC EDGAR (latest 10-K). Price data unavailable due to API changes."
    }' > "$DATA_FILE"

# Display results
echo ""
echo "✅ Data fetched successfully for $TICKER_UPPER"
echo "   File: $DATA_FILE"
echo ""

if [ "$REVENUE" != "N/A" ]; then
    echo "📊 Financial Data (from SEC):"
    [ "$COMPANY_NAME" != "N/A" ] && echo "   Company: $COMPANY_NAME"
    echo "   Revenue: \$$REVENUE"
    [ "$NET_INCOME" != "N/A" ] && echo "   Net Income: \$$NET_INCOME"
    [ "$TOTAL_ASSETS" != "N/A" ] && echo "   Total Assets: \$$TOTAL_ASSETS"
    [ "$OPERATING_INCOME" != "N/A" ] && echo "   Operating Income: \$$OPERATING_INCOME"
    echo ""
fi

echo "⚠️  Price data unavailable (Yahoo Finance requires authentication)"
echo "   Analysis will use SEC financial data only."
echo ""

echo "   Ready to run: ./analyze.sh $TICKER_UPPER --live"
