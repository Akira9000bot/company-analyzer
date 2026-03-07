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
AV_INCOME="$DATA_DIR/${TICKER_UPPER}_av_income.json"
AV_CASHFLOW="$DATA_DIR/${TICKER_UPPER}_av_cashflow.json"
AV_BALANCE="$DATA_DIR/${TICKER_UPPER}_av_balance.json"
COOKIE_FILE="$DATA_DIR/yahoo_cookie.txt"
# Alpha Vantage: key from OpenClaw auth profiles (profile alpha-vantage:default)
OPENCLAW_ROOT="${OPENCLAW_HOME:-${HOME}/.openclaw}"
AUTH_PROFILES="${OPENCLAW_AUTH_PROFILES:-${OPENCLAW_ROOT}/agents/main/agent/auth-profiles.json}"
mkdir -p "$DATA_DIR"

# Trace logging (same as pipeline/run-framework; writes to assets/traces/<TICKER>_<date>.trace)
source "$SCRIPT_DIR/lib/trace.sh"
init_trace
log_trace "INFO" "fetch_data" "Starting..."

# Separate User Agents 
# Yahoo requires a "Browser" agent. SEC requires a "Bot/Email" agent.
YAHOO_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
# SEC EDGAR requires a User-Agent with contact info. Set SEC_EDGAR_USER_AGENT or use placeholder.
SEC_AGENT="${SEC_EDGAR_USER_AGENT:-OpenClaw-Research-Bot/1.0 (mailto:your-email@example.com)}"

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

# Extract two most recent values (for YoY or trend). Echo "PRIOR CURR" (older first) or "N/A N/A".
extract_sec_two_latest() {
    local file="$1" unit="${2:-USD}" tag="$3"
    local arr
    arr=$(jq -r ".facts.\"us-gaap\"[\"$tag\"].units[\"$unit\"] | sort_by(.end) | if length >= 2 then .[-2:] | map(.val) | join(\" \") else \"N/A N/A\" end" "$file" 2>/dev/null)
    if [ -n "$arr" ] && [ "$arr" != "null" ] && [ "$arr" != "N/A N/A" ]; then
        echo "$arr"
    else
        echo "N/A N/A"
    fi
}

# Convert raw dollar values to millions for human-readable sector_context fields.
format_millions() {
    local val="${1:-}"
    if [[ -n "$val" && "$val" != "N/A" && "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        awk -v n="$val" 'BEGIN { printf "%.1f", n / 1000000 }'
    else
        echo "N/A"
    fi
}

# Convert values expressed in millions to raw-dollar integers for consistent math in JSON.
millions_to_dollars() {
    local val="${1:-}"
    if [[ -n "$val" && "$val" != "N/A" && "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        awk -v n="$val" 'BEGIN { printf "%.0f", n * 1000000 }'
    else
        echo "N/A"
    fi
}

percent_number() {
    local val="${1:-}"
    if [[ "$val" =~ ^(-?[0-9]+(\.[0-9]+)?)%$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$val"
    else
        echo "N/A"
    fi
}

# ============================================
# Step 1: Yahoo Finance Extraction
# ============================================
echo "🔍 Acquiring Yahoo Finance Session..."
curl -s -c "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://fc.yahoo.com" > /dev/null || true
CRUMB=$(curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://query1.finance.yahoo.com/v1/test/getcrumb" || echo "")

echo "🔍 Fetching Yahoo Finance data..."
curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" "https://query2.finance.yahoo.com/v7/finance/quote?symbols=${TICKER_UPPER}&crumb=${CRUMB}" > "${Y_RAW}_quote"

# Enriched modules: annual + quarterly income/cashflow, plus earningsTrend for guidance/revisions
curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" \
    "https://query2.finance.yahoo.com/v10/finance/quoteSummary/${TICKER_UPPER}?modules=earningsHistory,earningsTrend,assetProfile,defaultKeyStatistics,majorHoldersBreakdown,financialData,incomeStatementHistory,incomeStatementHistoryQuarterly,cashflowStatementHistory,cashflowStatementHistoryQuarterly&crumb=${CRUMB}" \
    > "${Y_RAW}_summary"
log_trace "INFO" "fetch_data" "Yahoo quoteSummary OK"

# ============================================
# Phase 1: Sector Detection (controls conditional power-metric extraction and sector_context)
# ============================================
SECTOR=$(jq -r '.quoteSummary.result[0].assetProfile.sector // "Other"' "${Y_RAW}_summary" 2>/dev/null || echo "Other")
SECTOR=$(echo "$SECTOR" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[ -z "$SECTOR" ] && SECTOR="Other"
case "$SECTOR" in
    "Technology"|"Communication Services") SECTOR_TYPE="TECH" ;;
    "Consumer Cyclical"|"Consumer Defensive") SECTOR_TYPE="RETAIL" ;;
    "Industrials"|"Basic Materials"|"Energy") SECTOR_TYPE="INDUSTRIAL" ;;
    "Financial Services") SECTOR_TYPE="FINANCE" ;;
    *) SECTOR_TYPE="GENERAL" ;;
esac
log_trace "INFO" "fetch_data" "sector=$SECTOR_TYPE ($SECTOR)"

# Power-metric placeholders (filled conditionally by sector + SEC/earnings)
SEC_RPO="N/A"
SEC_DEFERRED_REV="N/A"
INV_TURNOVER="N/A"
BACKLOG="N/A"
ASSET_TURNOVER="N/A"
NET_INTEREST_MARGIN="N/A"

DESC=$(jq -r '.quoteSummary.result[0].assetProfile.longBusinessSummary // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

# Extract ROE, margins, and ROA proxy from Yahoo financialData.
# Yahoo exposes returnOnAssets here, not true ROIC.
ROE=$(jq -r '.quoteSummary.result[0].financialData.returnOnEquity.fmt // .quoteSummary.result[0].financialData.returnOnEquity.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
GROSS_MARGIN=$(jq -r '.quoteSummary.result[0].financialData.grossMargins.fmt // .quoteSummary.result[0].financialData.grossMargins.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
OP_MARGIN=$(jq -r '.quoteSummary.result[0].financialData.operatingMargins.fmt // .quoteSummary.result[0].financialData.operatingMargins.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
ROA=$(jq -r '.quoteSummary.result[0].financialData.returnOnAssets.fmt // .quoteSummary.result[0].financialData.returnOnAssets.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")

PRICE=$(jq -r '.quoteResponse.result[0].regularMarketPrice // "N/A"' "${Y_RAW}_quote" 2>/dev/null || echo "N/A")
MCAP=$(jq -r '.quoteResponse.result[0].marketCap // "N/A"' "${Y_RAW}_quote" 2>/dev/null || echo "N/A")
# Analyst consensus 12-month target (Yahoo financialData) — used by synthesis for Price Target when present
TARGET_MEAN=$(jq -r '.quoteSummary.result[0].financialData.targetMeanPrice.raw // .quoteSummary.result[0].financialData.targetMeanPrice.fmt // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
TARGET_HIGH=$(jq -r '.quoteSummary.result[0].financialData.targetHighPrice.raw // .quoteSummary.result[0].financialData.targetHighPrice.fmt // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
TARGET_LOW=$(jq -r '.quoteSummary.result[0].financialData.targetLowPrice.raw // .quoteSummary.result[0].financialData.targetLowPrice.fmt // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
REVENUE_GROWTH_HINT_PCT=$(jq -r '.quoteSummary.result[0].financialData.revenueGrowth.raw // empty' "${Y_RAW}_summary" 2>/dev/null || echo "")
if [[ -n "$REVENUE_GROWTH_HINT_PCT" && "$REVENUE_GROWTH_HINT_PCT" =~ ^-?[0-9.]+$ ]]; then
    REVENUE_GROWTH_HINT_PCT=$(echo "scale=4; $REVENUE_GROWTH_HINT_PCT * 100" | bc 2>/dev/null || echo "")
fi
INSTITUTIONAL_OWNERSHIP_PCT=$(jq -r '.quoteSummary.result[0].majorHoldersBreakdown.institutionsPercentHeld.fmt // .quoteSummary.result[0].defaultKeyStatistics.heldPercentInstitutions.fmt // .quoteSummary.result[0].defaultKeyStatistics.heldPercentInstitutions.raw // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
INSTITUTIONS_COUNT=$(jq -r '.quoteSummary.result[0].majorHoldersBreakdown.institutionsCount.raw // .quoteSummary.result[0].majorHoldersBreakdown.institutionsCount.fmt // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
SURPRISE=$(jq -c '.quoteSummary.result[0].earningsHistory.history | .[-4:] | map({date: .quarter.fmt, surprise: .surprisePercent.fmt})' "${Y_RAW}_summary" 2>/dev/null || echo "[]")
CIK=$(jq -r '.quoteResponse.result[0].extra?.cik // empty' "${Y_RAW}_quote" 2>/dev/null || echo "")

# Forward EPS guidance and internal fair value anchors
GUIDANCE_EPS=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[]? | select(.period == "0y") | .earningsEstimate.avg.raw // .earningsEstimate.avg.fmt // empty' "${Y_RAW}_summary" 2>/dev/null | head -1)
[ -z "$GUIDANCE_EPS" ] && GUIDANCE_EPS=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[]? | select(.period == "+1y") | .earningsEstimate.avg.raw // .earningsEstimate.avg.fmt // empty' "${Y_RAW}_summary" 2>/dev/null | head -1)
GUIDANCE_EPS_LOW=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[]? | select(.period == "0y") | .earningsEstimate.low.raw // .earningsEstimate.low.fmt // empty' "${Y_RAW}_summary" 2>/dev/null | head -1)
GUIDANCE_EPS_HIGH=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[]? | select(.period == "0y") | .earningsEstimate.high.raw // .earningsEstimate.high.fmt // empty' "${Y_RAW}_summary" 2>/dev/null | head -1)
GUIDANCE_PERIOD=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[]? | select(.period == "0y") | .period // empty' "${Y_RAW}_summary" 2>/dev/null | head -1)
[ -z "$GUIDANCE_PERIOD" ] && GUIDANCE_PERIOD=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[]? | select(.period == "+1y") | .period // empty' "${Y_RAW}_summary" 2>/dev/null | head -1)
if [ -z "$GUIDANCE_EPS" ] && [[ -n "$GUIDANCE_EPS_LOW" && -n "$GUIDANCE_EPS_HIGH" && "$GUIDANCE_EPS_LOW" =~ ^-?[0-9.]+$ && "$GUIDANCE_EPS_HIGH" =~ ^-?[0-9.]+$ ]]; then
    GUIDANCE_EPS=$(echo "scale=4; ($GUIDANCE_EPS_LOW + $GUIDANCE_EPS_HIGH) / 2" | bc 2>/dev/null || echo "")
fi
GROWTH_MULTIPLE="N/A"
GROWTH_MULTIPLE_UNCAPPED="N/A"
GROWTH_MULTIPLE_CAP="N/A"
GROWTH_MULTIPLE_CAP_REASON="N/A"
INTERNAL_FAIR_VALUE="N/A"
GUIDANCE_FORWARD_PE="N/A"
PRIMARY_VALUATION_ANCHOR="N/A"
PRIMARY_VALUATION_ANCHOR_SOURCE="N/A"
VALUATION_CONTEXT="Standard"

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

# Revenue & Net Income YoY (QUARTERLY: Q0 = latest, Q-1 = prior quarter, Q-4 = same quarter last year)
MARGIN_INFLECTION="false"
SENTIMENT_INFLECTION="false"
REV_LAST_4="[]"
GM_LAST_4="[]"
LATEST_Q_GROSS_MARGIN_PCT="N/A"

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

    # Quarterly delta: Latest quarter (Q0) gross margin vs annual. Flag Margin Inflection if Q0 > annual by >200bps.
    Q0_REV=$(jq -r '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[0].totalRevenue.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    Q0_COST=$(jq -r '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[0].costOfRevenue.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    Q0_GP=$(jq -r '.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[0].grossProfit.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    # Use computed (rev - cost) only when cost is non-zero; when Yahoo reports 0/0 we cannot infer margin
    if { [ -z "$Q0_GP" ] || [ "$Q0_GP" = "0" ]; } && [ -n "$Q0_REV" ] && [ -n "$Q0_COST" ] && [ "$Q0_COST" != "0" ]; then
        Q0_GP=$(echo "scale=2; $Q0_REV - $Q0_COST" | bc 2>/dev/null || echo "")
    fi
    if [ "$Q0_GP" = "0" ]; then Q0_GP=""; fi
    if [ -n "$Q0_REV" ] && [ -n "$Q0_GP" ] && [ "$Q0_REV" != "0" ]; then
        LATEST_Q_GM_RAW=$(echo "scale=4; $Q0_GP / $Q0_REV" | bc 2>/dev/null || echo "")
        LATEST_Q_GROSS_MARGIN_PCT=$(echo "scale=2; $LATEST_Q_GM_RAW * 100" | bc 2>/dev/null || echo "N/A")
        # Annual gross margin: financialData.grossMargins.raw is decimal (e.g. 0.57); .fmt may be "57%"
        ANNUAL_GM_RAW=$(jq -r '.quoteSummary.result[0].financialData.grossMargins.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
        if [ -z "$ANNUAL_GM_RAW" ]; then
            ANNUAL_GM_FMT=$(jq -r '.quoteSummary.result[0].financialData.grossMargins.fmt // empty' "${Y_RAW}_summary" 2>/dev/null)
            if [[ "$ANNUAL_GM_FMT" =~ ^([0-9.]+)%?$ ]]; then
                VAL="${BASH_REMATCH[1]}"
                # If value is > 1 assume percentage (e.g. 57); if <= 1 assume decimal (e.g. 0.57)
                if [ "$(echo "scale=4; $VAL <= 1" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
                    ANNUAL_GM_RAW="$VAL"
                else
                    ANNUAL_GM_RAW=$(echo "scale=4; $VAL / 100" | bc 2>/dev/null || echo "")
                fi
            fi
        fi
        if [ -n "$LATEST_Q_GM_RAW" ] && [ -n "$ANNUAL_GM_RAW" ]; then
            # Loosened to 150 bps (1.5 pp) so clear margin expansion is flagged
            BPS_DIFF=$(echo "scale=4; ($LATEST_Q_GM_RAW - $ANNUAL_GM_RAW) * 10000" | bc 2>/dev/null || echo "0")
            BPS_GT_150=$(echo "scale=0; $BPS_DIFF > 150" | bc 2>/dev/null || echo "0")
            if [[ "$BPS_DIFF" =~ ^-?[0-9.]+$ ]] && [ "${BPS_GT_150:-0}" = "1" ]; then
                MARGIN_INFLECTION="true"
            fi
        fi
    fi

    # Last 4 quarters: revenue and gross_margin arrays (Q0 = latest .. Q3 = four quarters ago)
    REV_LAST_4=$(jq -c '[.quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[0:4][] | .totalRevenue.raw // 0]' "${Y_RAW}_summary" 2>/dev/null || echo "[]")
    GM_LAST_4=$(jq -c '
        .quoteSummary.result[0].incomeStatementHistoryQuarterly.incomeStatementHistory[0:4] |
        map(
            (if .grossProfit.raw != null and .grossProfit.raw != 0 then .grossProfit.raw
              elif .costOfRevenue.raw != null and .costOfRevenue.raw != 0 and .totalRevenue.raw != null then (.totalRevenue.raw - .costOfRevenue.raw)
              else null end) as $gp |
            if .totalRevenue.raw != null and .totalRevenue.raw != 0 and $gp != null and $gp > 0 then ($gp / .totalRevenue.raw) * 100 else null end
        )
    ' "${Y_RAW}_summary" 2>/dev/null || echo "[]")
fi

# Guidance & Trend: earningsTrend — current quarter estimate vs 7 days ago; upward revision = Sentiment Inflection
if jq -e '.quoteSummary.result[0].earningsTrend.trend' "${Y_RAW}_summary" > /dev/null 2>&1; then
    # Current quarter: trend[0] is usually current quarter; .estimate or .earningsEstimate.avg
    EST_CURR=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[0].estimate.raw // .quoteSummary.result[0].earningsTrend.trend[0].estimate.fmt // .quoteSummary.result[0].earningsTrend.trend[0].earningsEstimate.avg.raw // .quoteSummary.result[0].earningsTrend.trend[0].earningsEstimate.avg.fmt // empty' "${Y_RAW}_summary" 2>/dev/null)
    # 7 days ago: distinct key so we compare revision, not same value
    EST_7D=$(jq -r '.quoteSummary.result[0].earningsTrend.trend[0]["7daysAgo"].raw // .quoteSummary.result[0].earningsTrend.trend[0]["7daysAgo"].fmt // .quoteSummary.result[0].earningsTrend.trend[0].estimates["7daysAgo"] // empty' "${Y_RAW}_summary" 2>/dev/null)
    if [ -n "$EST_CURR" ] && [ -n "$EST_7D" ] && [ "$EST_CURR" != "null" ] && [ "$EST_7D" != "null" ] && [ "$EST_CURR" != "$EST_7D" ]; then
        if [[ "$EST_CURR" =~ ^-?[0-9.]+$ ]] && [[ "$EST_7D" =~ ^-?[0-9.]+$ ]]; then
            IS_UP=$(echo "scale=6; $EST_CURR > $EST_7D" | bc 2>/dev/null || echo "0")
            if [ "${IS_UP:-0}" = "1" ]; then
                SENTIMENT_INFLECTION="true"
            fi
        fi
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
SHARES_PRIOR="N/A"
SHARES_YOY_PCT="N/A"

# Fallback: gross margin from income statement if financialData missing (gross profit / revenue)
if [[ "$GROSS_MARGIN" == "N/A" || -z "$GROSS_MARGIN" ]]; then
    REV_IS=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].totalRevenue.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    COST_IS=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].costOfRevenue.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    if [[ -n "$REV_IS" && -n "$COST_IS" && "$REV_IS" != "0" ]]; then
        GROSS_MARGIN="$(echo "scale=2; ($REV_IS - $COST_IS) * 100 / $REV_IS" | bc 2>/dev/null)%"
    fi
fi
# Fallback: operating margin from income statement (operatingIncome / revenue)
if [[ "$OP_MARGIN" == "N/A" || -z "$OP_MARGIN" ]]; then
    REV_IS=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].totalRevenue.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    OP_INC=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].operatingIncome.raw // .quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].incomeFromOperations.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    if [[ -n "$REV_IS" && -n "$OP_INC" && "$REV_IS" != "0" ]]; then
        OP_MARGIN="$(echo "scale=2; $OP_INC * 100 / $REV_IS" | bc 2>/dev/null)%"
    fi
fi
[[ -z "$GROSS_MARGIN" ]] && GROSS_MARGIN="N/A"
[[ -z "$OP_MARGIN" ]] && OP_MARGIN="N/A"
[[ -z "$ROA" ]] && ROA="N/A"

# ============================================
# Step 3: SEC Data (Final Precision)
# ============================================
if [ -z "$CIK" ] || [ "$CIK" = "null" ]; then
    echo "🔍 Looking up SEC CIK..."
    # 1) Try SEC company_tickers.json (ticker -> CIK) for listed companies
    SEC_TICKERS=$(curl -s -H "User-Agent: $SEC_AGENT" "https://www.sec.gov/files/company_tickers.json" 2>/dev/null)
    if echo "$SEC_TICKERS" | jq -e '.' >/dev/null 2>&1; then
        CIK=$(echo "$SEC_TICKERS" | jq -r --arg t "$TICKER_UPPER" '[.[] | select(.ticker == $t) | .cik_str] | first // empty' 2>/dev/null)
    fi
    # 2) Fallback: browse-edgar by ticker (atom)
    if [ -z "$CIK" ]; then
        CIK=$(curl -s -H "User-Agent: $SEC_AGENT" "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&company=${TICKER_UPPER}&output=atom" | grep -o '<cik>[^<]*' | head -1 | sed 's/<cik>//' || echo "")
    fi
fi

REV="$CURR_REV"
NI="$CURR_NI"
if [ -n "$CIK" ]; then
    # Fix: Remove leading zeros and use base-10 to prevent octal conversion errors in printf
    CIK_CLEAN=$(echo "$CIK" | sed 's/^0*//')
    if [[ "$CIK_CLEAN" =~ ^[0-9]+$ ]] && [ -n "$CIK_CLEAN" ]; then
    CIK_PADDED=$(printf "%010d" "$CIK_CLEAN")
    echo "🔍 Fetching SEC financial facts for CIK: $CIK_PADDED"
    # 🚨 THE FIX: Use SEC_AGENT so EDGAR doesn't block the request with a 403 error
    if curl -s -H "User-Agent: $SEC_AGENT" "https://data.sec.gov/api/xbrl/companyfacts/CIK${CIK_PADDED}.json" -o "$SEC_FILE"; then
        if [ -s "$SEC_FILE" ] && jq -e '.facts' "$SEC_FILE" > /dev/null 2>&1; then
            log_trace "INFO" "fetch_data" "SEC companyfacts OK (CIK $CIK_PADDED)"
            # Fallback revenue and net income if Yahoo missing
            if [ "$REV" = "N/A" ] || [ "$NI" = "N/A" ]; then
                SEC_REV=$(extract_sec_value "$SEC_FILE" "USD" "Revenues" "SalesRevenueNet" "RevenueFromContractWithCustomerExcludingAssessedTax")
                SEC_NI=$(extract_sec_value "$SEC_FILE" "USD" "NetIncomeLoss" "ProfitLoss")
                [ "$REV" = "N/A" ] && REV="$SEC_REV"
                [ "$NI" = "N/A" ] && NI="$SEC_NI"
            fi

            # Share count trend: two latest SEC values for YoY (dilution vs buyback)
            # Try multiple SEC concept names and units (companies use different XBRL tags)
            SEC_SHARES_TWO=$(extract_sec_two_latest "$SEC_FILE" "shares" "CommonStockSharesOutstanding")
            [ "$SEC_SHARES_TWO" = "N/A N/A" ] && SEC_SHARES_TWO=$(extract_sec_two_latest "$SEC_FILE" "pure" "CommonStockSharesOutstanding")
            [ "$SEC_SHARES_TWO" = "N/A N/A" ] && SEC_SHARES_TWO=$(extract_sec_two_latest "$SEC_FILE" "shares" "CommonStockSharesIssued")
            [ "$SEC_SHARES_TWO" = "N/A N/A" ] && SEC_SHARES_TWO=$(extract_sec_two_latest "$SEC_FILE" "shares" "WeightedAverageNumberOfSharesOutstandingBasic")
            if [ "$SEC_SHARES_TWO" != "N/A N/A" ]; then
                SHARES_PRIOR=$(echo "$SEC_SHARES_TWO" | awk '{print $1}')
                SHARES_CURR_SEC=$(echo "$SEC_SHARES_TWO" | awk '{print $2}')
                if [[ -n "$SHARES_PRIOR" && -n "$SHARES_CURR_SEC" && "$SHARES_PRIOR" != "0" && "$SHARES_PRIOR" != "N/A" ]]; then
                    SHARES_YOY_PCT=$(echo "scale=2; ($SHARES_CURR_SEC - $SHARES_PRIOR) * 100 / $SHARES_PRIOR" | bc 2>/dev/null || echo "N/A")
                    # Prefer SEC current when we have SEC trend so all three (outstanding, prior, yoy_pct) are from same source
                    SHARES_OUT="$SHARES_CURR_SEC"
                else
                    SHARES_PRIOR="N/A"
                fi
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

            # Phase 2: Sector-specific "power metric" extraction (SEC tags)
            case "$SECTOR_TYPE" in
                TECH)
                    SEC_RPO=$(extract_sec_value "$SEC_FILE" "USD" "RevenueRemainingPerformanceObligation" "ContractWithCustomerLiability")
                    SEC_DEFERRED_REV=$(extract_sec_value "$SEC_FILE" "USD" "DeferredRevenue" "ContractWithCustomerLiability" "DeferredRevenueCurrent" "DeferredRevenueNoncurrent")
                    ;;
                RETAIL)
                    INV_RAW=$(extract_sec_value "$SEC_FILE" "USD" "InventoryNet" "Inventory")
                    COGS_RAW=$(extract_sec_value "$SEC_FILE" "USD" "CostOfGoodsSold" "CostOfRevenue")
                    if [[ -n "$INV_RAW" && "$INV_RAW" != "N/A" && "$INV_RAW" != "0" && -n "$COGS_RAW" && "$COGS_RAW" != "N/A" ]]; then
                        INV_TURNOVER=$(echo "scale=2; $COGS_RAW / $INV_RAW" | bc 2>/dev/null || echo "N/A")
                    fi
                    [ "$INV_TURNOVER" = "" ] && INV_TURNOVER="N/A"
                    ;;
                INDUSTRIAL)
                    BACKLOG=$(extract_sec_value "$SEC_FILE" "USD" "RevenueRemainingPerformanceObligation" "ContractWithCustomerLiability")
                    SEC_ASSETS=$(extract_sec_value "$SEC_FILE" "USD" "Assets")
                    if [[ -n "$SEC_ASSETS" && "$SEC_ASSETS" != "N/A" && "$SEC_ASSETS" != "0" && -n "$CURR_REV" && "$CURR_REV" != "N/A" ]]; then
                        ASSET_TURNOVER=$(echo "scale=4; $CURR_REV / $SEC_ASSETS" | bc 2>/dev/null || echo "N/A")
                    fi
                    [ "$ASSET_TURNOVER" = "" ] && ASSET_TURNOVER="N/A"
                    ;;
                FINANCE)
                    NET_INT_INC=$(extract_sec_value "$SEC_FILE" "USD" "NetInterestIncome" "InterestIncomeExpenseNet")
                    INT_EARN_ASSETS=$(extract_sec_value "$SEC_FILE" "USD" "InterestEarningAssets" "Assets")
                    if [[ -n "$INT_EARN_ASSETS" && "$INT_EARN_ASSETS" != "N/A" && "$INT_EARN_ASSETS" != "0" && -n "$NET_INT_INC" && "$NET_INT_INC" != "N/A" ]]; then
                        NET_INTEREST_MARGIN=$(echo "scale=2; $NET_INT_INC * 100 / $INT_EARN_ASSETS" | bc 2>/dev/null || echo "N/A")
                    fi
                    [ "$NET_INTEREST_MARGIN" = "" ] && NET_INTEREST_MARGIN="N/A"
                    ;;
                *) ;;
            esac
        fi
    else
        log_trace "INFO" "fetch_data" "SEC fetch failed (curl or empty response)"
    fi
    fi
else
    log_trace "INFO" "fetch_data" "SEC skipped (no CIK)"
fi

# ============================================
# Step 3.5: Alpha Vantage fallback (FCF, revenue_q_yoy)
# Key from OpenClaw auth profiles (profile alpha-vantage:default).
# Uses up to 2 API calls when key is set and Yahoo/SEC left any of these N/A.
# ============================================
AV_KEY=""
if [ -f "$AUTH_PROFILES" ]; then
    AV_KEY=$(jq -r '.profiles["alpha-vantage:default"].key // empty' "$AUTH_PROFILES" 2>/dev/null || true)
fi
NEED_AV_INCOME="0"
echo "$GM_LAST_4" | jq -e 'any(. == null)' >/dev/null 2>&1 && NEED_AV_INCOME="1"
[[ "$REV_Q_YOY" = "N/A" ]] && NEED_AV_INCOME="1"
if [[ -n "$AV_KEY" && ( "$FCF" = "N/A" || "$REV_Q_YOY" = "N/A" || "$SHARES_PRIOR" = "N/A" || "$NEED_AV_INCOME" = "1" ) ]]; then
    log_trace "INFO" "fetch_data" "Alpha Vantage fallback (FCF/revenue_q_yoy/shares/gross_margin)"
    echo "🔍 Alpha Vantage fallback for FCF / revenue_q_yoy / share count trend / quarterly gross margin..."
    BASE_AV="https://www.alphavantage.co/query"
    if [ "$REV_Q_YOY" = "N/A" ] || [ "$NEED_AV_INCOME" = "1" ]; then
        curl -s "${BASE_AV}?function=INCOME_STATEMENT&symbol=${TICKER_UPPER}&apikey=${AV_KEY}" -o "$AV_INCOME"
        if ! jq -e '.["Error Message"] // .["Note"]' "$AV_INCOME" >/dev/null 2>&1; then
            # quarterlyReports: [0]=latest, [4]=same quarter prior year (if 5 quarters available)
            REV_Q_CURR=$(jq -r '.quarterlyReports[0].totalRevenue // empty' "$AV_INCOME" 2>/dev/null)
            # Same quarter prior year requires at least 5 quarterly rows; do NOT fall back to [1] (prior quarter),
            # because that would turn a YoY metric into a sequential comparison and silently misstate growth.
            REV_Q_PREV=$(jq -r '.quarterlyReports[4].totalRevenue // empty' "$AV_INCOME" 2>/dev/null)
            if [[ -n "$REV_Q_CURR" && -n "$REV_Q_PREV" && "$REV_Q_PREV" != "0" ]]; then
                REV_Q_YOY=$(echo "scale=4; ($REV_Q_CURR - $REV_Q_PREV) * 100 / $REV_Q_PREV" | bc 2>/dev/null || echo "N/A")
            fi
            # Quarterly gross margin from AV when Yahoo had nulls: grossProfit/totalRevenue*100 or (revenue-cost)/revenue
            if [ "$NEED_AV_INCOME" = "1" ]; then
                GM_AV=$(jq -c '
                    [.quarterlyReports[0:4][] |
                        (.totalRevenue | if type == "string" then (tonumber? // empty) else . end) as $rev |
                        (.grossProfit | if type == "string" then (tonumber? // empty) else . end) as $gp |
                        ((.costOfRevenue // .costOfGoodsAndServicesSold) | if type == "string" then (tonumber? // empty) else . end) as $cost |
                        (if $rev != null and $rev != 0 then
                            (if $gp != null and $gp > 0 then ($gp / $rev) * 100
                             elif $cost != null and (($rev - $cost) > 0) then (($rev - $cost) / $rev) * 100
                             else null end)
                         else null end)]
                ' "$AV_INCOME" 2>/dev/null || echo "[]")
                if [ -n "$GM_AV" ] && [ "$GM_AV" != "[]" ] && echo "$GM_AV" | jq -e 'length > 0 and (.[0] != null)' >/dev/null 2>&1; then
                    GM_LAST_4="$GM_AV"
                    LATEST_Q_GROSS_MARGIN_PCT=$(echo "$GM_AV" | jq -r '.[0] | if . != null then (. * 100 | floor / 100 | tostring) else "N/A" end' 2>/dev/null || echo "N/A")
                fi
            fi
        fi
        sleep 2
    fi
    if [ "$FCF" = "N/A" ]; then
        curl -s "${BASE_AV}?function=CASH_FLOW&symbol=${TICKER_UPPER}&apikey=${AV_KEY}" -o "$AV_CASHFLOW"
        if ! jq -e '.["Error Message"] // .["Note"]' "$AV_CASHFLOW" >/dev/null 2>&1; then
            # Alpha Vantage: operatingCashflow, capitalExpenditures (capex often negative)
            OP_CF_AV=$(jq -r '.annualReports[0].operatingCashflow // empty' "$AV_CASHFLOW" 2>/dev/null)
            CAPEX_AV=$(jq -r '.annualReports[0].capitalExpenditures // empty' "$AV_CASHFLOW" 2>/dev/null)
            if [[ -n "$OP_CF_AV" && "$OP_CF_AV" != "None" ]]; then
                if [[ -n "$CAPEX_AV" && "$CAPEX_AV" != "None" && "$CAPEX_AV" != "0" ]]; then
                    # Capex is typically negative; FCF = operating + capex (e.g. 100 + (-20) = 80)
                    FCF=$(echo "scale=0; $OP_CF_AV + $CAPEX_AV" | bc 2>/dev/null || echo "$OP_CF_AV")
                else
                    FCF="$OP_CF_AV"
                fi
            fi
        fi
    fi
    # Share count trend: quarterly balance sheet has commonStockSharesOutstanding
    if [ "$SHARES_PRIOR" = "N/A" ]; then
        curl -s "${BASE_AV}?function=BALANCE_SHEET&symbol=${TICKER_UPPER}&apikey=${AV_KEY}" -o "$AV_BALANCE"
        if ! jq -e '.["Error Message"] // .["Note"]' "$AV_BALANCE" >/dev/null 2>&1; then
            AV_SHARES_CURR=$(jq -r '.quarterlyReports[0].commonStockSharesOutstanding // empty' "$AV_BALANCE" 2>/dev/null)
            AV_SHARES_PRIOR=$(jq -r '.quarterlyReports[4].commonStockSharesOutstanding // .quarterlyReports[1].commonStockSharesOutstanding // empty' "$AV_BALANCE" 2>/dev/null)
            if [[ -n "$AV_SHARES_CURR" && -n "$AV_SHARES_PRIOR" && "$AV_SHARES_PRIOR" != "0" && "$AV_SHARES_PRIOR" != "None" ]]; then
                SHARES_PRIOR="$AV_SHARES_PRIOR"
                SHARES_YOY_PCT=$(echo "scale=2; ($AV_SHARES_CURR - $AV_SHARES_PRIOR) * 100 / $AV_SHARES_PRIOR" | bc 2>/dev/null || echo "N/A")
                [ "$SHARES_OUT" = "N/A" ] && SHARES_OUT="$AV_SHARES_CURR"
            fi
        fi
        sleep 2
    fi
    rm -f "$AV_INCOME" "$AV_CASHFLOW" "$AV_BALANCE"
fi

# When Yahoo (and AV if used) did not provide quarterly gross margin, fill with annual so trend is visible
QUARTERLY_GM_IMPUTED="false"
ANNUAL_GM_PCT=""
if [[ "$GROSS_MARGIN" =~ ^([0-9.]+)%?$ ]]; then
    VAL="${BASH_REMATCH[1]}"
    if [ "$(echo "scale=4; $VAL <= 1" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
        ANNUAL_GM_PCT=$(echo "scale=2; $VAL * 100" | bc 2>/dev/null)
    else
        ANNUAL_GM_PCT=$(echo "scale=2; $VAL" | bc 2>/dev/null)
    fi
fi
if [ -n "$ANNUAL_GM_PCT" ] && [ "$(echo "scale=2; $ANNUAL_GM_PCT > 0" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
    if echo "$GM_LAST_4" | jq -e 'any(. == null)' >/dev/null 2>&1; then
        GM_LAST_4=$(echo "$GM_LAST_4" | jq -c --arg pct "$ANNUAL_GM_PCT" 'map(if . == null then ($pct | tonumber) else . end)' 2>/dev/null || echo "$GM_LAST_4")
        QUARTERLY_GM_IMPUTED="true"
    fi
    if [ "$LATEST_Q_GROSS_MARGIN_PCT" = "N/A" ] || [ -z "$LATEST_Q_GROSS_MARGIN_PCT" ]; then
        LATEST_Q_GROSS_MARGIN_PCT="$ANNUAL_GM_PCT"
    fi
fi

# ============================================
# Step 3.9: Optional earnings release (latest quarter GAAP / non-GAAP gross margin, RPO, compute/AI segment)
# Sources for EARNINGS_URL (in order): env EARNINGS_URL, .cache/data/<TICKER>_earnings_url.txt, auto-discovery from Yahoo company website.
# RPO and compute_and_ai_* are optional: null for non-SaaS or when not in the release (no error; skip in analysis).
# ============================================
LATEST_Q_GAAP_GM_PCT=""
LATEST_Q_NON_GAAP_GM_PCT=""
RPO_MILLIONS=""
RPO_YOY_PCT=""
FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS=""
COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT=""
FULL_YEAR_GUIDANCE_EPS_LOW=""
FULL_YEAR_GUIDANCE_EPS_HIGH=""
RESOLVED_EARNINGS_URL=""
EARNINGS_URL="${EARNINGS_URL:-}"
EARNINGS_SOURCE=""
[ -n "$EARNINGS_URL" ] && EARNINGS_SOURCE="env"
[ -z "$EARNINGS_URL" ] && [ -f "${DATA_DIR}/${TICKER_UPPER}_earnings_url.txt" ] && EARNINGS_URL=$(cat "${DATA_DIR}/${TICKER_UPPER}_earnings_url.txt" | head -1) && EARNINGS_SOURCE="file"
# Auto-discover from Yahoo assetProfile.website → IR page → first earnings-like link (if still no URL)
if [ -z "$EARNINGS_URL" ] && [ -f "${Y_RAW}_summary" ]; then
    log_trace "INFO" "fetch_data" "earnings_url discovery attempting..."
    DISCOVERED=$(YAHOO_SUMMARY_JSON="${Y_RAW}_summary" TICKER="$TICKER_UPPER" bash "$SCRIPT_DIR/lib/discover_earnings_url.sh" 2>/dev/null | head -1)
    DISCOVERED=$(echo "${DISCOVERED:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$DISCOVERED" ] && echo "$DISCOVERED" | grep -qE '^https?://'; then
        EARNINGS_URL="$DISCOVERED"
        EARNINGS_SOURCE="discovered"
        echo "$EARNINGS_URL" > "${DATA_DIR}/${TICKER_UPPER}_earnings_url.txt"
        echo "📎 Discovered earnings URL and saved to ${DATA_DIR}/${TICKER_UPPER}_earnings_url.txt"
        log_trace "INFO" "fetch_data" "earnings_url discovery found, saved to file"
    else
        log_trace "INFO" "fetch_data" "earnings_url discovery none"
    fi
fi
[ -n "$EARNINGS_URL" ] && [ -z "$EARNINGS_SOURCE" ] && EARNINGS_SOURCE="file"
if [ -n "$EARNINGS_URL" ]; then
    log_trace "INFO" "fetch_data" "earnings_url source=$EARNINGS_SOURCE, parsing..."
    echo "🔍 Parsing earnings release (gross margin, RPO, non-GAAP net income, compute/AI growth)..."
    PARSED=$(EARNINGS_URL="$EARNINGS_URL" bash "$SCRIPT_DIR/lib/parse_earnings_gross_margin.sh" 2>/dev/null) || true
    if [ -n "$PARSED" ]; then
        eval "$(echo "$PARSED" | grep -E '^(LATEST_Q_(GAAP|NON_GAAP)_GM_PCT|RPO_MILLIONS|RPO_YOY_PCT|FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS|COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT|FULL_YEAR_GUIDANCE_EPS_(LOW|HIGH)|RESOLVED_EARNINGS_URL)=')"
        if [ -n "${RESOLVED_EARNINGS_URL:-}" ] && [ "$RESOLVED_EARNINGS_URL" != "$EARNINGS_URL" ]; then
            EARNINGS_URL="$RESOLVED_EARNINGS_URL"
            echo "$EARNINGS_URL" > "${DATA_DIR}/${TICKER_UPPER}_earnings_url.txt"
            log_trace "INFO" "fetch_data" "earnings_url normalized to resolved release URL"
        fi
        # Prefer explicit earnings-release margin over a stale or annual fallback for the latest quarter.
        for v in "$LATEST_Q_GAAP_GM_PCT" "$LATEST_Q_NON_GAAP_GM_PCT"; do
            if [[ -n "$v" && "$v" != "N/A" && "$v" =~ ^[0-9.]+$ ]]; then
                LATEST_Q_GROSS_MARGIN_PCT="$v"
                break
            fi
        done
        # If quarterly trend is flat/imputed because upstream quarterly data is missing, rebuild it from recent releases.
        if [ "$QUARTERLY_GM_IMPUTED" = "true" ] || echo "$GM_LAST_4" | jq -e 'length > 0 and ((unique | length) == 1)' >/dev/null 2>&1; then
            GM_EARNINGS=$(EARNINGS_URL="$EARNINGS_URL" bash "$SCRIPT_DIR/lib/build_earnings_gm_trend.sh" 2>/dev/null || echo "[]")
            if echo "$GM_EARNINGS" | jq -e 'length >= 2 and ((unique | length) > 1)' >/dev/null 2>&1; then
                GM_LAST_4="$GM_EARNINGS"
                QUARTERLY_GM_IMPUTED="false"
                log_trace "INFO" "fetch_data" "gross_margin trend rebuilt from earnings releases"
            fi
        fi
        log_trace "INFO" "fetch_data" "earnings_parser OK"
    else
        log_trace "WARN" "fetch_data" "earnings_parser no output (parse failed or empty)"
    fi
    # Margin inflection fallback: if still false, compare latest-q margin (earnings or Yahoo) to annual
    if [ "$MARGIN_INFLECTION" = "false" ]; then
        LATEST_PCT=""
        for v in "$LATEST_Q_NON_GAAP_GM_PCT" "$LATEST_Q_GAAP_GM_PCT" "$LATEST_Q_GROSS_MARGIN_PCT"; do
            if [[ -n "$v" && "$v" != "N/A" && "$v" =~ ^[0-9.]+$ ]]; then LATEST_PCT="$v"; break; fi
        done
        ANNUAL_PCT=""
        if [[ "$GROSS_MARGIN" =~ ^([0-9.]+)%?$ ]]; then ANNUAL_PCT="${BASH_REMATCH[1]}"; fi
        if [[ -n "$LATEST_PCT" && -n "$ANNUAL_PCT" ]] && [[ "$LATEST_PCT" =~ ^[0-9.]+$ && "$ANNUAL_PCT" =~ ^[0-9.]+$ ]]; then
            PP_DIFF=$(echo "scale=2; $LATEST_PCT - $ANNUAL_PCT" | bc 2>/dev/null || echo "0")
            GT_150=$(echo "scale=0; $PP_DIFF > 1.5" | bc 2>/dev/null || echo "0")
            [ "${GT_150:-0}" = "1" ] && MARGIN_INFLECTION="true"
        fi
    fi
else
    log_trace "INFO" "fetch_data" "earnings_parser skipped (no URL)"
fi

# Sentiment inflection fallback: strong recent earnings beats (2+ quarters positive surprise) when 7d estimate revision not available
if [ "$SENTIMENT_INFLECTION" = "false" ] && [ -n "$SURPRISE" ] && [ "$SURPRISE" != "[]" ]; then
    BEATS=$(echo "$SURPRISE" | jq -r '[.[] | .surprise | gsub("%"; "") | gsub(","; "") | tonumber? // 0] | map(select(. > 0)) | length' 2>/dev/null || echo "0")
    if [ -n "$BEATS" ] && [ "${BEATS:-0}" -ge 2 ]; then
        SENTIMENT_INFLECTION="true"
    fi
fi

# Final fallback for quarterly revenue YoY:
# Yahoo's financialData.revenueGrowth is often the latest quarter YoY growth even when quarterly history only has 4 rows.
if [[ "$REV_Q_YOY" = "N/A" || -z "$REV_Q_YOY" ]] && [[ -n "$REVENUE_GROWTH_HINT_PCT" && "$REVENUE_GROWTH_HINT_PCT" =~ ^-?[0-9.]+$ ]]; then
    REV_Q_YOY=$(printf "%.4f" "$REVENUE_GROWTH_HINT_PCT" 2>/dev/null || echo "$REVENUE_GROWTH_HINT_PCT")
    log_trace "INFO" "fetch_data" "revenue_q_yoy fallback=financialData.revenueGrowth (${REV_Q_YOY}%)"
fi

# Normalize and quality-check optional money metrics BEFORE valuation logic so bad RPO parses
# cannot affect guidance multiple caps or anchors.
RPO_DOLLARS="N/A"
FULL_YEAR_NON_GAAP_NI_DOLLARS="N/A"
RPO_COVERAGE_RATIO="N/A"
RPO_QUALITY_STATUS="missing"
RPO_SOURCE="missing"
if [ -n "${FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS:-}" ]; then
    FULL_YEAR_NON_GAAP_NI_DOLLARS=$(millions_to_dollars "$FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS")
fi

# Candidate 1: earnings-release RPO (usually millions)
if [[ "${RPO_MILLIONS:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    CANDIDATE_RPO_DOLLARS=$(millions_to_dollars "$RPO_MILLIONS")
    CANDIDATE_RPO_MILLIONS="$RPO_MILLIONS"
    CANDIDATE_RPO_YOY="${RPO_YOY_PCT:-N/A}"
    CANDIDATE_RPO_COVERAGE="N/A"
    CANDIDATE_RPO_STATUS="present_unchecked"
    if [[ "$CANDIDATE_RPO_DOLLARS" =~ ^-?[0-9]+$ ]] && [[ "$CURR_REV" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$CURR_REV > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
        CANDIDATE_RPO_COVERAGE=$(awk -v rpo="$CANDIDATE_RPO_DOLLARS" -v rev="$CURR_REV" 'BEGIN { printf "%.4f", rpo / rev }')
        CANDIDATE_RPO_STATUS="valid"
        if [ "$SECTOR_TYPE" = "TECH" ] && [ "$(echo "$CANDIDATE_RPO_COVERAGE < 0.01" | bc 2>/dev/null || echo 0)" = "1" ]; then
            CANDIDATE_RPO_STATUS="suspect_too_small_vs_revenue"
        fi
    fi
    if [ "$CANDIDATE_RPO_STATUS" = "valid" ] || [ "$CANDIDATE_RPO_STATUS" = "present_unchecked" ]; then
        RPO_DOLLARS="$CANDIDATE_RPO_DOLLARS"
        RPO_COVERAGE_RATIO="$CANDIDATE_RPO_COVERAGE"
        RPO_QUALITY_STATUS="$CANDIDATE_RPO_STATUS"
        RPO_SOURCE="earnings_release"
    else
        RPO_MILLIONS="N/A"
        RPO_YOY_PCT="N/A"
        RPO_QUALITY_STATUS="$CANDIDATE_RPO_STATUS"
        log_trace "WARN" "fetch_data" "earnings-release RPO rejected as implausibly small vs revenue"
    fi
fi

# Candidate 2: SEC companyfacts RPO fallback if earnings-release RPO was missing or rejected.
if [[ ("$RPO_QUALITY_STATUS" = "missing" || "$RPO_QUALITY_STATUS" = "suspect_too_small_vs_revenue") && "${SEC_RPO:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    CANDIDATE_RPO_DOLLARS=$(awk -v n="$SEC_RPO" 'BEGIN { printf "%.0f", n }')
    CANDIDATE_RPO_MILLIONS=$(format_millions "$SEC_RPO")
    CANDIDATE_RPO_COVERAGE="N/A"
    CANDIDATE_RPO_STATUS="present_unchecked"
    if [[ "$CANDIDATE_RPO_DOLLARS" =~ ^-?[0-9]+$ ]] && [[ "$CURR_REV" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$CURR_REV > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
        CANDIDATE_RPO_COVERAGE=$(awk -v rpo="$CANDIDATE_RPO_DOLLARS" -v rev="$CURR_REV" 'BEGIN { printf "%.4f", rpo / rev }')
        CANDIDATE_RPO_STATUS="valid"
        if [ "$SECTOR_TYPE" = "TECH" ] && [ "$(echo "$CANDIDATE_RPO_COVERAGE < 0.01" | bc 2>/dev/null || echo 0)" = "1" ]; then
            CANDIDATE_RPO_STATUS="suspect_too_small_vs_revenue"
        fi
    fi
    if [ "$CANDIDATE_RPO_STATUS" = "valid" ] || [ "$CANDIDATE_RPO_STATUS" = "present_unchecked" ]; then
        RPO_DOLLARS="$CANDIDATE_RPO_DOLLARS"
        RPO_MILLIONS="$CANDIDATE_RPO_MILLIONS"
        RPO_YOY_PCT="N/A"
        RPO_COVERAGE_RATIO="$CANDIDATE_RPO_COVERAGE"
        RPO_QUALITY_STATUS="$CANDIDATE_RPO_STATUS"
        RPO_SOURCE="sec_companyfacts"
        log_trace "INFO" "fetch_data" "RPO fallback accepted from SEC companyfacts"
    else
        RPO_DOLLARS="N/A"
        RPO_MILLIONS="N/A"
        RPO_YOY_PCT="N/A"
        RPO_COVERAGE_RATIO="N/A"
        RPO_QUALITY_STATUS="$CANDIDATE_RPO_STATUS"
        log_trace "WARN" "fetch_data" "SEC RPO rejected as implausibly small vs revenue"
    fi
fi

# Momentum-adjusted valuation anchors: use forward EPS guidance and analyst high target, not just mean target.
if [[ -n "$FULL_YEAR_GUIDANCE_EPS_LOW" && "$FULL_YEAR_GUIDANCE_EPS_LOW" != "N/A" && "$FULL_YEAR_GUIDANCE_EPS_LOW" =~ ^-?[0-9.]+$ ]] && \
   [[ -n "$FULL_YEAR_GUIDANCE_EPS_HIGH" && "$FULL_YEAR_GUIDANCE_EPS_HIGH" != "N/A" && "$FULL_YEAR_GUIDANCE_EPS_HIGH" =~ ^-?[0-9.]+$ ]]; then
    GUIDANCE_EPS=$(awk -v a="$FULL_YEAR_GUIDANCE_EPS_LOW" -v b="$FULL_YEAR_GUIDANCE_EPS_HIGH" 'BEGIN { printf "%.4f", (a + b) / 2 }' 2>/dev/null || echo "$GUIDANCE_EPS")
    GUIDANCE_EPS_LOW="$FULL_YEAR_GUIDANCE_EPS_LOW"
    GUIDANCE_EPS_HIGH="$FULL_YEAR_GUIDANCE_EPS_HIGH"
    GUIDANCE_PERIOD="release_guidance"
fi
if [[ -n "$GUIDANCE_EPS" && "$GUIDANCE_EPS" != "N/A" && "$GUIDANCE_EPS" =~ ^-?[0-9.]+$ ]]; then
    GROWTH_SIGNAL_PCT="$REV_Q_YOY"
    if [[ -z "$GROWTH_SIGNAL_PCT" || "$GROWTH_SIGNAL_PCT" = "N/A" || ! "$GROWTH_SIGNAL_PCT" =~ ^-?[0-9.]+$ ]]; then
        GROWTH_SIGNAL_PCT="$REVENUE_GROWTH_HINT_PCT"
    fi
    POSITIVE_NI="0"
    POSITIVE_FCF="0"
    [[ "$CURR_NI" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$CURR_NI > 0" | bc 2>/dev/null || echo 0)" = "1" ] && POSITIVE_NI="1"
    [[ "$FCF" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$FCF > 0" | bc 2>/dev/null || echo 0)" = "1" ] && POSITIVE_FCF="1"
    case "$SECTOR_TYPE" in
        TECH)
            if [[ "$GROWTH_SIGNAL_PCT" =~ ^-?[0-9.]+$ ]] && [ "$(echo "$GROWTH_SIGNAL_PCT >= 20" | bc 2>/dev/null || echo 0)" = "1" ]; then
                GROWTH_MULTIPLE="75"
            elif [ "$MARGIN_INFLECTION" = "true" ]; then
                GROWTH_MULTIPLE="60"
            else
                GROWTH_MULTIPLE="45"
            fi
            ;;
        RETAIL)
            # High-growth commerce / fintech platforms should not be forced into a mature retail multiple.
            if [[ "$GROWTH_SIGNAL_PCT" =~ ^-?[0-9.]+$ ]] && [ "$(echo "$GROWTH_SIGNAL_PCT > 30" | bc 2>/dev/null || echo 0)" = "1" ]; then
                GROWTH_MULTIPLE="40"
            elif [[ "$GROWTH_SIGNAL_PCT" =~ ^-?[0-9.]+$ ]] && [ "$(echo "$GROWTH_SIGNAL_PCT >= 15" | bc 2>/dev/null || echo 0)" = "1" ]; then
                GROWTH_MULTIPLE="30"
            elif [ "$POSITIVE_NI" = "1" ] && [ "$POSITIVE_FCF" = "1" ]; then
                GROWTH_MULTIPLE="25"
            else
                GROWTH_MULTIPLE="22"
            fi
            ;;
        INDUSTRIAL) GROWTH_MULTIPLE="20" ;;
        FINANCE) GROWTH_MULTIPLE="12" ;;
        *) GROWTH_MULTIPLE="18" ;;
    esac
    GROWTH_MULTIPLE_UNCAPPED="$GROWTH_MULTIPLE"
    # Cap guidance multiples for slower, mature names so internal targets remain grounded.
    # This approximates lifecycle maturity without depending on 01-phase output.
    if [[ "$GROWTH_SIGNAL_PCT" =~ ^-?[0-9.]+$ ]] && [ "$(echo "$GROWTH_SIGNAL_PCT >= 20" | bc 2>/dev/null || echo 0)" = "1" ]; then
        GROWTH_MULTIPLE_CAP="100"
        GROWTH_MULTIPLE_CAP_REASON="high_growth_cap"
    elif [[ "${COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT:-}" =~ ^-?[0-9.]+$ ]] && [ "$(echo "${COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT} >= 40" | bc 2>/dev/null || echo 0)" = "1" ]; then
        GROWTH_MULTIPLE_CAP="100"
        GROWTH_MULTIPLE_CAP_REASON="ai_pivot_cap"
    elif [[ "${RPO_YOY_PCT:-}" =~ ^-?[0-9.]+$ ]] && [ "$(echo "${RPO_YOY_PCT} >= 40" | bc 2>/dev/null || echo 0)" = "1" ]; then
        GROWTH_MULTIPLE_CAP="100"
        GROWTH_MULTIPLE_CAP_REASON="rpo_surge_cap"
    elif [[ "$GROWTH_SIGNAL_PCT" =~ ^-?[0-9.]+$ ]] && [ "$(echo "$GROWTH_SIGNAL_PCT < 15" | bc 2>/dev/null || echo 0)" = "1" ] && [ "$POSITIVE_NI" = "1" ] && [ "$POSITIVE_FCF" = "1" ]; then
        GROWTH_MULTIPLE_CAP="25"
        GROWTH_MULTIPLE_CAP_REASON="mature_growth_cap"
    else
        GROWTH_MULTIPLE_CAP="60"
        GROWTH_MULTIPLE_CAP_REASON="inflection_growth_cap"
    fi
    if [[ "$GROWTH_MULTIPLE" =~ ^[0-9.]+$ && "$GROWTH_MULTIPLE_CAP" =~ ^[0-9.]+$ ]] && [ "$(echo "$GROWTH_MULTIPLE > $GROWTH_MULTIPLE_CAP" | bc 2>/dev/null || echo 0)" = "1" ]; then
        GROWTH_MULTIPLE="$GROWTH_MULTIPLE_CAP"
    fi
    if [[ "$GROWTH_MULTIPLE" =~ ^[0-9.]+$ ]]; then
        INTERNAL_FAIR_VALUE=$(echo "scale=2; $GUIDANCE_EPS * $GROWTH_MULTIPLE" | bc 2>/dev/null || echo "N/A")
        if [[ "$PRICE" =~ ^[0-9.]+$ ]] && [ "$(echo "$GUIDANCE_EPS > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
            GUIDANCE_FORWARD_PE=$(echo "scale=2; $PRICE / $GUIDANCE_EPS" | bc 2>/dev/null || echo "N/A")
        fi
    fi
fi

PRIMARY_VAL_NUM=""
if [[ "$TARGET_HIGH" =~ ^[0-9.]+$ ]]; then
    PRIMARY_VAL_NUM="$TARGET_HIGH"
    PRIMARY_VALUATION_ANCHOR_SOURCE="analyst_high_target"
fi
if [[ "$INTERNAL_FAIR_VALUE" =~ ^[0-9.]+$ ]]; then
    # Be conservative: if both primary anchors exist, prefer the lower / more demanding one.
    if [ -z "$PRIMARY_VAL_NUM" ] || [ "$(echo "$INTERNAL_FAIR_VALUE < $PRIMARY_VAL_NUM" | bc 2>/dev/null || echo 0)" = "1" ]; then
        PRIMARY_VAL_NUM="$INTERNAL_FAIR_VALUE"
        PRIMARY_VALUATION_ANCHOR_SOURCE="internal_guidance_target"
    fi
fi
[ -n "$PRIMARY_VAL_NUM" ] && PRIMARY_VALUATION_ANCHOR="$PRIMARY_VAL_NUM"

if [[ "$PRICE" =~ ^[0-9.]+$ ]] && [ -n "$PRIMARY_VAL_NUM" ] && [ "$(echo "$PRIMARY_VAL_NUM > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
    PREMIUM_PCT=$(echo "scale=2; ($PRICE - $PRIMARY_VAL_NUM) * 100 / $PRIMARY_VAL_NUM" | bc 2>/dev/null || echo "")
    if [[ "$TARGET_HIGH" =~ ^[0-9.]+$ ]] && [[ "$TARGET_MEAN" =~ ^[0-9.]+$ ]] && [[ "$INTERNAL_FAIR_VALUE" =~ ^[0-9.]+$ ]] && \
       [ "$(echo "$PRICE > $TARGET_HIGH" | bc 2>/dev/null || echo 0)" = "1" ] && \
       [ "$(echo "$PRICE > $TARGET_MEAN" | bc 2>/dev/null || echo 0)" = "1" ] && \
       [ "$(echo "$PRICE > $INTERNAL_FAIR_VALUE" | bc 2>/dev/null || echo 0)" = "1" ]; then
        VALUATION_CONTEXT="Breakout Momentum (Trading above all targets)"
    elif [[ "$PREMIUM_PCT" =~ ^-?[0-9.]+$ ]] && [ "$(echo "$PREMIUM_PCT <= 10" | bc 2>/dev/null || echo 0)" = "1" ] && [ "$(echo "$PREMIUM_PCT >= -10" | bc 2>/dev/null || echo 0)" = "1" ]; then
        VALUATION_CONTEXT="Near primary valuation anchor"
    elif [[ "$PREMIUM_PCT" =~ ^-?[0-9.]+$ ]] && [ "$(echo "$PREMIUM_PCT > 10" | bc 2>/dev/null || echo 0)" = "1" ]; then
        VALUATION_CONTEXT="Above primary valuation anchor"
    else
        VALUATION_CONTEXT="Below primary valuation anchor"
    fi
fi
log_trace "INFO" "fetch_data" "valuation anchor=${PRIMARY_VALUATION_ANCHOR_SOURCE} value=${PRIMARY_VALUATION_ANCHOR}"
if [[ "$GROWTH_MULTIPLE_UNCAPPED" =~ ^[0-9.]+$ ]] && [[ "$GROWTH_MULTIPLE" =~ ^[0-9.]+$ ]]; then
    log_trace "INFO" "fetch_data" "guidance multiple raw=${GROWTH_MULTIPLE_UNCAPPED} final=${GROWTH_MULTIPLE} cap=${GROWTH_MULTIPLE_CAP:-N/A} reason=${GROWTH_MULTIPLE_CAP_REASON:-N/A}"
fi

# ============================================
# Phase 3: Sector-specific power_metrics payload (for sector_context; tells AI which lens to use)
# ============================================
SECTOR_DATA="{}"
case "$SECTOR_TYPE" in
    TECH)
        RPO_VAL="${RPO_MILLIONS:-$SEC_RPO}"
        [ "$RPO_VAL" = "" ] && RPO_VAL="N/A"
        if [[ "$RPO_VAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$RPO_VAL > 1000000" | bc 2>/dev/null || echo 0)" = "1" ]; then
            RPO_VAL=$(format_millions "$RPO_VAL")
        fi
        AI_VAL="${COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT:-N/A}"
        [ "$AI_VAL" = "" ] && AI_VAL="N/A"
        DEF_REV_VAL=$(format_millions "$SEC_DEFERRED_REV")
        SECTOR_DATA=$(jq -n --arg rpo "$RPO_VAL" --arg rpo_dollars "$RPO_DOLLARS" --arg rpo_cov "$RPO_COVERAGE_RATIO" --arg rpo_quality "$RPO_QUALITY_STATUS" --arg ai "$AI_VAL" --arg def_rev "$DEF_REV_VAL" --arg def_rev_dollars "$SEC_DEFERRED_REV" \
            '{key_metric: "RPO", value: $rpo, value_dollars: (if $rpo_dollars != "" and $rpo_dollars != "N/A" then ($rpo_dollars | tonumber?) else null end), rpo_coverage_ratio: (if $rpo_cov != "" and $rpo_cov != "N/A" then ($rpo_cov | tonumber?) else null end), rpo_quality_status: (if $rpo_quality != "" then $rpo_quality else "missing" end), ai_pivot_growth_pct: $ai, deferred_revenue: $def_rev, deferred_revenue_dollars: (if $def_rev_dollars != "" and $def_rev_dollars != "N/A" then ($def_rev_dollars | tonumber?) else null end)}' 2>/dev/null || echo "{}")
        ;;
    RETAIL)
        SECTOR_DATA=$(jq -n --arg turn "$INV_TURNOVER" --arg gm "$GROSS_MARGIN" \
            '{key_metric: "Inventory Turnover", value: $turn, gross_margin: $gm}' 2>/dev/null || echo "{}")
        ;;
    INDUSTRIAL)
        SECTOR_DATA=$(jq -n --arg backlog "$BACKLOG" --arg at "$ASSET_TURNOVER" --arg roa "$ROA" \
            '{key_metric: "Backlog", value: $backlog, asset_turnover: $at, roa: $roa}' 2>/dev/null || echo "{}")
        ;;
    FINANCE)
        SECTOR_DATA=$(jq -n --arg nim "$NET_INTEREST_MARGIN" --arg roe "$ROE" \
            '{key_metric: "Net Interest Margin", value: $nim, roe: $roe}' 2>/dev/null || echo "{}")
        ;;
    *) SECTOR_DATA=$(jq -n '{}' 2>/dev/null || echo "{}") ;;
esac
[ -z "$SECTOR_DATA" ] && SECTOR_DATA="{}"
echo "$SECTOR_DATA" | jq -e . >/dev/null 2>&1 || SECTOR_DATA="{}"

# ============================================
# Step 4: Final JSON Compilation (with quarterly_trend, inflection flags, sector_context)
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
    --arg shares_prior "$SHARES_PRIOR" \
    --arg shares_yoy_pct "$SHARES_YOY_PCT" \
    --arg price "$PRICE" \
    --arg cap "$MCAP" \
    --arg target_mean "$TARGET_MEAN" \
    --arg target_high "$TARGET_HIGH" \
    --arg target_low "$TARGET_LOW" \
    --arg guidance_eps "${GUIDANCE_EPS:-}" \
    --arg guidance_eps_low "${GUIDANCE_EPS_LOW:-}" \
    --arg guidance_eps_high "${GUIDANCE_EPS_HIGH:-}" \
    --arg guidance_period "${GUIDANCE_PERIOD:-}" \
    --arg growth_multiple "$GROWTH_MULTIPLE" \
    --arg growth_multiple_uncapped "$GROWTH_MULTIPLE_UNCAPPED" \
    --arg growth_multiple_cap "$GROWTH_MULTIPLE_CAP" \
    --arg growth_multiple_cap_reason "$GROWTH_MULTIPLE_CAP_REASON" \
    --arg internal_fair_value "$INTERNAL_FAIR_VALUE" \
    --arg guidance_forward_pe "$GUIDANCE_FORWARD_PE" \
    --arg valuation_context "$VALUATION_CONTEXT" \
    --arg primary_anchor "$PRIMARY_VALUATION_ANCHOR" \
    --arg primary_anchor_source "$PRIMARY_VALUATION_ANCHOR_SOURCE" \
    --arg institutional_ownership_pct "$INSTITUTIONAL_OWNERSHIP_PCT" \
    --arg institutions_count "$INSTITUTIONS_COUNT" \
    --arg roe "$ROE" \
    --arg gross_margin "$GROSS_MARGIN" \
    --arg op_margin "$OP_MARGIN" \
    --arg roa "$ROA" \
    --arg latest_q_gross_margin "$LATEST_Q_GROSS_MARGIN_PCT" \
    --arg latest_q_gaap_gm "${LATEST_Q_GAAP_GM_PCT:-}" \
    --arg latest_q_non_gaap_gm "${LATEST_Q_NON_GAAP_GM_PCT:-}" \
    --arg rpo_millions "${RPO_MILLIONS:-}" \
    --arg rpo_dollars "${RPO_DOLLARS:-}" \
    --arg rpo_coverage_ratio "${RPO_COVERAGE_RATIO:-}" \
    --arg rpo_quality_status "${RPO_QUALITY_STATUS:-}" \
    --arg rpo_yoy_pct "${RPO_YOY_PCT:-}" \
    --arg full_year_non_gaap_ni "${FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS:-}" \
    --arg full_year_non_gaap_ni_dollars "${FULL_YEAR_NON_GAAP_NI_DOLLARS:-}" \
    --arg compute_ai_growth_pct "${COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT:-}" \
    --arg margin_inflection "$MARGIN_INFLECTION" \
    --arg sentiment_inflection "$SENTIMENT_INFLECTION" \
    --arg quarterly_gm_imputed "$QUARTERLY_GM_IMPUTED" \
    --argjson surprise "$SURPRISE" \
    --argjson rev_last_4 "$REV_LAST_4" \
    --argjson gm_last_4 "$GM_LAST_4" \
    --arg sector "$SECTOR" \
    --arg sector_type "$SECTOR_TYPE" \
    --argjson sector_data "$SECTOR_DATA" \
    '{
        ticker: $ticker,
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        company_profile: { name: $ticker, description: $desc },
        sector_context: { sector: $sector, category: $sector_type, power_metrics: $sector_data },
        financial_metrics: { 
            revenue: $rev, 
            net_income: $ni, 
            roe: $roe,
            gross_margin: $gross_margin,
            operating_margin: $op_margin,
            roa: $roa,
            revenue_yoy: $rev_yoy,
            net_income_yoy: $ni_yoy,
            revenue_q: $rev_q,
            net_income_q: $ni_q,
            revenue_q_yoy: $rev_q_yoy,
            net_income_q_yoy: $ni_q_yoy,
            fcf: $fcf,
            shares_outstanding: $shares_out,
            shares_prior: $shares_prior,
            shares_yoy_pct: $shares_yoy_pct,
            latest_q_gross_margin_pct: $latest_q_gross_margin,
            latest_q_gaap_gross_margin_pct: (if $latest_q_gaap_gm != "" and $latest_q_gaap_gm != "N/A" then $latest_q_gaap_gm else null end),
            latest_q_non_gaap_gross_margin_pct: (if $latest_q_non_gaap_gm != "" and $latest_q_non_gaap_gm != "N/A" then $latest_q_non_gaap_gm else null end),
            # Optional (null for non-SaaS or when not reported in earnings):
            remaining_performance_obligations_rpo: (if $rpo_dollars != "" and $rpo_dollars != "N/A" then ($rpo_dollars | tonumber?) else null end),
            remaining_performance_obligations_rpo_millions: (if $rpo_millions != "" and $rpo_millions != "N/A" then ($rpo_millions | tonumber?) else null end),
            rpo_coverage_ratio: (if $rpo_coverage_ratio != "" and $rpo_coverage_ratio != "N/A" then ($rpo_coverage_ratio | tonumber?) else null end),
            rpo_quality_status: (if $rpo_quality_status != "" then $rpo_quality_status else "missing" end),
            rpo_yoy_pct: (if $rpo_yoy_pct != "" and $rpo_yoy_pct != "N/A" then ($rpo_yoy_pct | tonumber?) else null end),
            compute_and_ai_revenue_growth_yoy_pct: (if $compute_ai_growth_pct != "" and $compute_ai_growth_pct != "N/A" then ($compute_ai_growth_pct | tonumber?) else null end),
            full_year_non_gaap_net_income: (if $full_year_non_gaap_ni_dollars != "" and $full_year_non_gaap_ni_dollars != "N/A" then ($full_year_non_gaap_ni_dollars | tonumber?) else null end),
            full_year_non_gaap_net_income_millions: (if $full_year_non_gaap_ni != "" and $full_year_non_gaap_ni != "N/A" then ($full_year_non_gaap_ni | tonumber?) else null end),
            margin_inflection: ($margin_inflection == "true"),
            sentiment_inflection: ($sentiment_inflection == "true"),
            quarterly_gross_margin_imputed: ($quarterly_gm_imputed == "true"),
            quarterly_trend: { revenue: $rev_last_4, gross_margin: $gm_last_4 }
        },
        valuation: {
            current_price: $price,
            market_cap: $cap,
            target_mean_price: $target_mean,
            target_high_price: $target_high,
            target_low_price: $target_low,
            analyst_mean_target: $target_mean,
            analyst_high_target: $target_high,
            internal_guidance_target: (if $internal_fair_value != "" and $internal_fair_value != "N/A" then $internal_fair_value else null end),
            guidance_eps: (if $guidance_eps != "" and $guidance_eps != "N/A" then $guidance_eps else null end),
            guidance_eps_low: (if $guidance_eps_low != "" and $guidance_eps_low != "N/A" then $guidance_eps_low else null end),
            guidance_eps_high: (if $guidance_eps_high != "" and $guidance_eps_high != "N/A" then $guidance_eps_high else null end),
            guidance_period: (if $guidance_period != "" then $guidance_period else null end),
            guidance_growth_multiple: (if $growth_multiple != "" and $growth_multiple != "N/A" then $growth_multiple else null end),
            guidance_growth_multiple_uncapped: (if $growth_multiple_uncapped != "" and $growth_multiple_uncapped != "N/A" then $growth_multiple_uncapped else null end),
            guidance_growth_multiple_cap: (if $growth_multiple_cap != "" and $growth_multiple_cap != "N/A" then $growth_multiple_cap else null end),
            guidance_growth_multiple_cap_reason: (if $growth_multiple_cap_reason != "" and $growth_multiple_cap_reason != "N/A" then $growth_multiple_cap_reason else null end),
            guidance_forward_pe: (if $guidance_forward_pe != "" and $guidance_forward_pe != "N/A" then $guidance_forward_pe else null end),
            primary_valuation_anchor: (if $primary_anchor != "" and $primary_anchor != "N/A" then $primary_anchor else null end),
            primary_valuation_anchor_source: (if $primary_anchor_source != "" and $primary_anchor_source != "N/A" then $primary_anchor_source else null end),
            valuation_context: $valuation_context,
            institutional_ownership_pct: $institutional_ownership_pct,
            institutions_count: $institutions_count
        },
        momentum: { earnings_surprises: $surprise }
    }' > "$DATA_FILE"

# Cleanup
rm -f "$SEC_FILE" "${Y_RAW}_quote" "${Y_RAW}_summary" "$COOKIE_FILE"
log_trace "INFO" "fetch_data" "Complete | $DATA_FILE"
echo "✅ Data ready: $DATA_FILE"