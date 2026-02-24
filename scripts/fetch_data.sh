#!/bin/bash
# fetch_data.sh - Dual-Agent Resilient Hybrid
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKER_UPPER=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
[ -z "$TICKER_UPPER" ] && { echo "Usage: $0 <TICKER>"; exit 1; }

DATA_DIR="$(dirname "$SCRIPT_DIR")/.cache/data"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"
AV_RAW="$DATA_DIR/${TICKER_UPPER}_av_raw.json"
Y_RAW="$DATA_DIR/${TICKER_UPPER}_yahoo_raw.json"
SEC_FILE="$DATA_DIR/${TICKER_UPPER}_sec_raw.json"
COOKIE_FILE="$DATA_DIR/yahoo_cookie.txt"
mkdir -p "$DATA_DIR"

# 🚨 THE FIX: Separate User Agents 
# Yahoo requires a "Browser" agent. SEC requires a "Bot/Email" agent.
YAHOO_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
SEC_AGENT="akira9000bot@gmail.com" # Required by SEC EDGAR guidelines

# Load AV Key
AUTH_PROFILES="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
AV_KEY=$(jq -r '.profiles["alpha-vantage:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || echo "")

# ============================================
# Helper: SEC Value Extraction
# ============================================
extract_sec_value() {
    local file="$1"; local unit="${2:-USD}"; shift 2
    for tag in "$@"; do
        local val=$(jq -r ".facts.\"us-gaap\"[\"$tag\"].units[\"$unit\"] | sort_by(.end) | last | .val // empty" "$file" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" != "null" ]; then echo "$val"; return 0; fi
    done
    echo "N/A"
}

# ============================================
# Step 1: Attempt Alpha Vantage
# ============================================
USE_YAHOO=false
if [ -n "$AV_KEY" ]; then
    echo "📊 Attempting Alpha Vantage for $TICKER_UPPER..."
    curl -s "https://www.alphavantage.co/query?function=OVERVIEW&symbol=${TICKER_UPPER}&apikey=${AV_KEY}" -o "$AV_RAW"
    
    if grep -q "standard API rate limit\|Thank you for using Alpha Vantage" "$AV_RAW"; then
        echo "⚠️ AV Rate Limit detected. Falling back to Yahoo Finance..."
        USE_YAHOO=true
    elif ! jq -e '.Symbol' "$AV_RAW" > /dev/null 2>&1; then
        echo "⚠️ AV response invalid. Falling back to Yahoo Finance..."
        USE_YAHOO=true
    fi
else
    USE_YAHOO=true
fi

# ============================================
# Step 2: Yahoo Fallback Logic & Extraction
# ============================================
if [ "$USE_YAHOO" = true ]; then
    echo "🔍 Acquiring Yahoo Finance Session..."
    curl -s -c "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://fc.yahoo.com" > /dev/null || true
    CRUMB=$(curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://query1.finance.yahoo.com/v1/test/getcrumb" || echo "")

    echo "🔍 Fetching Yahoo Finance data..."
    curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://query2.finance.yahoo.com/v7/finance/quote?symbols=${TICKER_UPPER}&crumb=${CRUMB}" > "${Y_RAW}_quote"
    
    # 🚨 THE FIX: Added 'financialData' to the modules request
    curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://query2.finance.yahoo.com/v10/finance/quoteSummary/${TICKER_UPPER}?modules=earningsHistory,assetProfile,defaultKeyStatistics,financialData&crumb=${CRUMB}" > "${Y_RAW}_summary"
    
    DESC=$(jq -r '.quoteSummary.result[0].assetProfile.longBusinessSummary // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    
    # Extract ROE from financialData where it actually lives
    ROE=$(jq -r '.quoteSummary.result[0].financialData.returnOnEquity.fmt // .quoteSummary.result[0].financialData.returnOnEquity.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    
    # Robust PEG extraction (handles empty objects)
    PEG=$(jq -r '.quoteSummary.result[0].defaultKeyStatistics.pegRatio | if type == "object" then (.fmt // .raw // "N/A") else (. // "N/A") end' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    
    PRICE=$(jq -r '.quoteResponse.result[0].regularMarketPrice // "N/A"' "${Y_RAW}_quote" 2>/dev/null || echo "N/A")
    MCAP=$(jq -r '.quoteResponse.result[0].marketCap // "N/A"' "${Y_RAW}_quote" 2>/dev/null || echo "N/A")
    SURPRISE=$(jq -c '.quoteSummary.result[0].earningsHistory.history | .[-4:] | map({date: .quarter.fmt, surprise: .surprisePercent.fmt})' "${Y_RAW}_summary" 2>/dev/null || echo "[]")
    CIK=$(jq -r '.quoteResponse.result[0].extra?.cik // empty' "${Y_RAW}_quote" 2>/dev/null || echo "")
else
    DESC=$(jq -r '.Description // "N/A"' "$AV_RAW" 2>/dev/null || echo "N/A")
    ROE=$(jq -r '.ReturnOnEquityTTM // "N/A"' "$AV_RAW" 2>/dev/null || echo "N/A")
    PEG=$(jq -r '.PEGRatio // "N/A"' "$AV_RAW" 2>/dev/null || echo "N/A")
    MCAP=$(jq -r '.MarketCapitalization // "N/A"' "$AV_RAW" 2>/dev/null || echo "N/A")
    CIK=$(jq -r '.CIK // empty' "$AV_RAW" 2>/dev/null || echo "")
    [ "$CIK" = "None" ] && CIK=""
    PRICE=$(curl -s -H "User-Agent: $YAHOO_AGENT" "https://query1.finance.yahoo.com/v7/finance/quote?symbols=${TICKER_UPPER}" | jq -r '.quoteResponse.result[0].regularMarketPrice // "N/A"' || echo "N/A")
    SURPRISE="[]"
fi

# ============================================
# Step 3: SEC Data (Final Precision)
# ============================================
if [ -z "$CIK" ] || [ "$CIK" = "null" ]; then
    echo "🔍 Looking up SEC CIK directly..."
    # Use SEC Agent here
    CIK=$(curl -s -H "User-Agent: $SEC_AGENT" "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}&output=atom" | grep -o '<cik>[^<]*' | head -1 | sed 's/<cik>//' || echo "")
fi

REV="N/A"
NI="N/A"
if [ -n "$CIK" ]; then
    # Fix: Remove leading zeros and use base-10 to prevent octal conversion errors in printf
    CIK_CLEAN=$(echo "$CIK" | sed 's/^0*//')
    CIK_PADDED=$(printf "%010d" "$CIK_CLEAN")
    echo "🔍 Fetching SEC financial facts for CIK: $CIK_PADDED"
    # 🚨 THE FIX: Use SEC_AGENT so EDGAR doesn't block the request with a 403 error
    if curl -s -H "User-Agent: $SEC_AGENT" "https://data.sec.gov/api/xbrl/companyfacts/CIK${CIK_PADDED}.json" -o "$SEC_FILE"; then
        if [ -s "$SEC_FILE" ] && jq -e '.facts' "$SEC_FILE" > /dev/null 2>&1; then
            REV=$(extract_sec_value "$SEC_FILE" "USD" "Revenues" "SalesRevenueNet" "RevenueFromContractWithCustomerExcludingAssessedTax")
            NI=$(extract_sec_value "$SEC_FILE" "USD" "NetIncomeLoss" "ProfitLoss")
        fi
    fi
fi

# ============================================
# Step 4: Final JSON Compilation
# ============================================
echo "💾 Compiling Unified Dataset..."
jq -n \
    --arg ticker "$TICKER_UPPER" \
    --arg desc "$DESC" \
    --arg rev "$REV" \
    --arg ni "$NI" \
    --arg price "$PRICE" \
    --arg cap "$MCAP" \
    --arg roe "$ROE" \
    --arg peg "$PEG" \
    --argjson surprise "$SURPRISE" \
    '{
        ticker: $ticker,
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        company_profile: { name: $ticker, description: $desc },
        financial_metrics: { revenue: $rev, net_income: $ni, roe: $roe },
        valuation: { current_price: $price, market_cap: $cap, peg_ratio: $peg },
        momentum: { earnings_surprises: $surprise },
        sec_data: { 
            item1: ("Business: " + $desc + "\nEarnings Momentum: " + ($surprise | tostring)), 
            item1a: "Analyze risks based on valuation and historical volatility."
        }
    }' > "$DATA_FILE"

# Cleanup
rm -f "$AV_RAW" "$SEC_FILE" "${Y_RAW}_quote" "${Y_RAW}_summary" "$COOKIE_FILE"
echo "✅ Data ready: $DATA_FILE"