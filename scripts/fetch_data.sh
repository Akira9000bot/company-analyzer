#!/bin/bash
# fetch_data.sh - Dual-Agent Resilient Hybrid
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKER_UPPER=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
[ -z "$TICKER_UPPER" ] && { echo "Usage: $0 <TICKER>"; exit 1; }

DATA_DIR="$(dirname "$SCRIPT_DIR")/.cache/data"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"
Y_RAW="$DATA_DIR/${TICKER_UPPER}_yahoo_raw.json"
SEC_FILE="$DATA_DIR/${TICKER_UPPER}_sec_raw.json"
COOKIE_FILE="$DATA_DIR/yahoo_cookie.txt"
mkdir -p "$DATA_DIR"

# Separate User Agents 
# Yahoo requires a "Browser" agent. SEC requires a "Bot/Email" agent.
YAHOO_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
SEC_AGENT="akira9000bot@gmail.com" # Required by SEC EDGAR guidelines

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
# Step 1: Yahoo Finance Extraction
# ============================================
echo "🔍 Acquiring Yahoo Finance Session..."
curl -s -c "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://fc.yahoo.com" > /dev/null || true
CRUMB=$(curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://query1.finance.yahoo.com/v1/test/getcrumb" || echo "")

echo "🔍 Fetching Yahoo Finance data..."
curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://query2.finance.yahoo.com/v7/finance/quote?symbols=${TICKER_UPPER}&crumb=${CRUMB}" > "${Y_RAW}_quote"

# Enriched modules: add annual and quarterly income/cashflow statements
curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" \
    "https://query2.finance.yahoo.com/v10/finance/quoteSummary/${TICKER_UPPER}?modules=earningsHistory,assetProfile,defaultKeyStatistics,financialData,incomeStatementHistory,incomeStatementHistoryQuarterly,cashflowStatementHistory,cashflowStatementHistoryQuarterly&crumb=${CRUMB}" \
    > "${Y_RAW}_summary"

DESC=$(jq -r '.quoteSummary.result[0].assetProfile.longBusinessSummary // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

# Extract ROE from financialData where it actually lives
ROE=$(jq -r '.quoteSummary.result[0].financialData.returnOnEquity.fmt // .quoteSummary.result[0].financialData.returnOnEquity.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

# Robust PEG extraction (handles empty objects)
PEG=$(jq -r '.quoteSummary.result[0].defaultKeyStatistics.pegRatio | if type == "object" then (.fmt // .raw // "N/A") else (. // "N/A") end' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

PRICE=$(jq -r '.quoteResponse.result[0].regularMarketPrice // "N/A"' "${Y_RAW}_quote" 2>/dev/null || echo "N/A")
MCAP=$(jq -r '.quoteResponse.result[0].marketCap // "N/A"' "${Y_RAW}_quote" 2>/dev/null || echo "N/A")
SURPRISE=$(jq -c '.quoteSummary.result[0].earningsHistory.history | .[-4:] | map({date: .quarter.fmt, surprise: .surprisePercent.fmt})' "${Y_RAW}_summary" 2>/dev/null || echo "[]")
CIK=$(jq -r '.quoteResponse.result[0].extra?.cik // empty' "${Y_RAW}_quote" 2>/dev/null || echo "")

# Derived fundamentals from Yahoo
REV_YOY="N/A"          # annual YoY
NI_YOY="N/A"           # annual YoY
REV_Q_YOY="N/A"        # quarterly YoY (same quarter prior year)
NI_Q_YOY="N/A"         # quarterly YoY
FCF="N/A"              # annual FCF
SHARES_OUT="N/A"
CURR_REV="N/A"         # latest annual revenue
CURR_NI="N/A"          # latest annual net income
CURR_REV_Q="N/A"       # latest quarterly revenue
CURR_NI_Q="N/A"        # latest quarterly net income

# Revenue & Net Income YoY (ANNUAL: from incomeStatementHistory, most recent vs previous year)
if jq -e '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory' "${Y_RAW}_summary" > /dev/null 2>&1; then
    CURR_REV=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].totalRevenue.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    PREV_REV=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[1].totalRevenue.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    CURR_NI=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].netIncome.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    PREV_NI=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[1].netIncome.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

    if [[ "$CURR_REV" != "N/A" && "$PREV_REV" != "N/A" && "$PREV_REV" != "0" ]]; then
        REV_YOY=$(echo "scale=4; ($CURR_REV - $PREV_REV) * 100 / $PREV_REV" | bc 2>/dev/null || echo "N/A")
    fi
    if [[ "$CURR_NI" != "N/A" && "$PREV_NI" != "N/A" && "$PREV_NI" != "0" ]]; then
        NI_YOY=$(echo "scale=4; ($CURR_NI - $PREV_NI) * 100 / $PREV_NI" | bc 2>/dev/null || echo "N/A")
    fi
fi

# Revenue & Net Income YoY (QUARTERLY: from incomeStatementHistoryQuarterly, latest vs same qtr prior year)
if jq -e '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory' "${Y_RAW}_summary" > /dev/null 2>&1; then
    CURR_REV_Q=$(jq -r '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[0].totalRevenue.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    CURR_NI_Q=$(jq -r '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[0].netIncome.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    # Same quarter last year is typically index 4 if history is quarterly and ordered latest-first
    PREV_REV_Q=$(jq -r '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[4].totalRevenue.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    PREV_NI_Q=$(jq -r '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[4].netIncome.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

    if [[ "$CURR_REV_Q" != "N/A" && "$PREV_REV_Q" != "N/A" && "$PREV_REV_Q" != "0" ]]; then
        REV_Q_YOY=$(echo "scale=4; ($CURR_REV_Q - $PREV_REV_Q) * 100 / $PREV_REV_Q" | bc 2>/dev/null || echo "N/A")
    fi
    if [[ "$CURR_NI_Q" != "N/A" && "$PREV_NI_Q" != "N/A" && "$PREV_NI_Q" != "0" ]]; then
        NI_Q_YOY=$(echo "scale=4; ($CURR_NI_Q - $PREV_NI_Q) * 100 / $PREV_NI_Q" | bc 2>/dev/null || echo "N/A")
    fi
fi

# Free Cash Flow (from cashflowStatementHistory, prefer freeCashFlow, fallback to opCF - capex)
if jq -e '.quoteSummary.result[0].cashflowStatementHistory.cashflowStatements' "${Y_RAW}_summary" > /dev/null 2>&1; then
    FCF_RAW=$(jq -r '.quoteSummary.result[0].cashflowStatementHistory.cashflowStatements[0].freeCashFlow.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
    if [[ "$FCF_RAW" != "N/A" && "$FCF_RAW" != "null" ]]; then
        FCF="$FCF_RAW"
    else
        OP_CF=$(jq -r '.quoteSummary.result[0].cashflowStatementHistory.cashflowStatements[0].totalCashFromOperatingActivities.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
        CAPEX=$(jq -r '.quoteSummary.result[0].cashflowStatementHistory.cashflowStatements[0].capitalExpenditures.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
        if [[ "$OP_CF" != "N/A" && "$CAPEX" != "N/A" ]]; then
            FCF=$(echo "scale=2; $OP_CF - $CAPEX" | bc 2>/dev/null || echo "N/A")
        fi
    fi
fi

# Shares outstanding (proxy for dilution / buybacks)
SHARES_OUT=$(jq -r '.quoteSummary.result[0].defaultKeyStatistics.sharesOutstanding.raw // .quoteSummary.result[0].defaultKeyStatistics.sharesOutstanding // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

# ============================================
# Step 3: SEC Data (Final Precision)
# ============================================
if [ -z "$CIK" ] || [ "$CIK" = "null" ]; then
    echo "🔍 Looking up SEC CIK directly..."
    # Use SEC Agent here
    CIK=$(curl -s -H "User-Agent: $SEC_AGENT" "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=${TICKER_UPPER}&output=atom" | grep -o '<cik>[^<]*' | head -1 | sed 's/<cik>//' || echo "")
fi

REV="$CURR_REV"
NI="$CURR_NI"
if [ -n "$CIK" ]; then
    # Fix: Remove leading zeros and use base-10 to prevent octal conversion errors in printf
    CIK_CLEAN=$(echo "$CIK" | sed 's/^0*//')
    CIK_PADDED=$(printf "%010d" "$CIK_CLEAN")
    echo "🔍 Fetching SEC financial facts for CIK: $CIK_PADDED"
    # 🚨 THE FIX: Use SEC_AGENT so EDGAR doesn't block the request with a 403 error
    if curl -s -H "User-Agent: $SEC_AGENT" "https://data.sec.gov/api/xbrl/companyfacts/CIK${CIK_PADDED}.json" -o "$SEC_FILE"; then
        if [ -s "$SEC_FILE" ] && jq -e '.facts' "$SEC_FILE" > /dev/null 2>&1; then
            # Fallback revenue and net income if Yahoo missing
            if [ "$REV" = "N/A" ] || [ "$NI" = "N/A" ]; then
                SEC_REV=$(extract_sec_value "$SEC_FILE" "USD" "Revenues" "SalesRevenueNet" "RevenueFromContractWithCustomerExcludingAssessedTax")
                SEC_NI=$(extract_sec_value "$SEC_FILE" "USD" "NetIncomeLoss" "ProfitLoss")
                [ "$REV" = "N/A" ] && REV="$SEC_REV"
                [ "$NI" = "N/A" ] && NI="$SEC_NI"
            fi

            # FCF fallback: operating cash flow minus capex
            if [ "$FCF" = "N/A" ]; then
                SEC_OP_CF=$(extract_sec_value "$SEC_FILE" "USD" \
                    "NetCashProvidedByUsedInOperatingActivities" \
                    "NetCashProvidedByUsedInOperatingActivitiesContinuingOperations")
                SEC_CAPEX=$(extract_sec_value "$SEC_FILE" "USD" \
                    "PaymentsToAcquirePropertyPlantAndEquipment" \
                    "PaymentsToAcquireProductiveAssets")
                if [[ "$SEC_OP_CF" != "N/A" && "$SEC_CAPEX" != "N/A" ]]; then
                    FCF=$(echo "scale=2; $SEC_OP_CF - $SEC_CAPEX" | bc 2>/dev/null || echo "N/A")
                fi
            fi
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
    --arg rev_yoy "$REV_YOY" \
    --arg ni_yoy "$NI_YOY" \
    --arg rev_q "$CURR_REV_Q" \
    --arg ni_q "$CURR_NI_Q" \
    --arg rev_q_yoy "$REV_Q_YOY" \
    --arg ni_q_yoy "$NI_Q_YOY" \
    --arg fcf "$FCF" \
    --arg shares_out "$SHARES_OUT" \
    --arg price "$PRICE" \
    --arg cap "$MCAP" \
    --arg roe "$ROE" \
    --arg peg "$PEG" \
    --argjson surprise "$SURPRISE" \
    '{
        ticker: $ticker,
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        company_profile: { name: $ticker, description: $desc },
        financial_metrics: { 
            revenue: $rev, 
            net_income: $ni, 
            roe: $roe,
            revenue_yoy: $rev_yoy,
            net_income_yoy: $ni_yoy,
            revenue_q: $rev_q,
            net_income_q: $ni_q,
            revenue_q_yoy: $rev_q_yoy,
            net_income_q_yoy: $ni_q_yoy,
            fcf: $fcf,
            shares_outstanding: $shares_out
        },
        valuation: { current_price: $price, market_cap: $cap, peg_ratio: $peg },
        momentum: { earnings_surprises: $surprise }
    }' > "$DATA_FILE"

# Cleanup
rm -f "$SEC_FILE" "${Y_RAW}_quote" "${Y_RAW}_summary" "$COOKIE_FILE"
echo "✅ Data ready: $DATA_FILE"