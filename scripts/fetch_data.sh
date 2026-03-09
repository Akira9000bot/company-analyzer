#!/bin/bash
# fetch_data.sh - SEC EDGAR first, Yahoo for the rest.
# Financials (revenue, income, FCF, shares, RPO, quarterly trend, filing URL) come from fetch_edgar.sh (SEC).
# Quote, sector, description, analyst targets, guidance, earnings surprises, institutional ownership come from Yahoo.
# For post-earnings runs use: ./analyze.sh TICKER --live --refresh (or run this script directly).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKER_UPPER=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
[ -z "$TICKER_UPPER" ] && { echo "Usage: $0 <TICKER>"; exit 1; }

DATA_DIR="$(dirname "$SCRIPT_DIR")/.cache/data"
DATA_FILE="$DATA_DIR/${TICKER_UPPER}_data.json"
EDGAR_JSON="$DATA_DIR/${TICKER_UPPER}_edgar.json"   # Used only during build; merged into _data.json then removed
Y_RAW="$DATA_DIR/${TICKER_UPPER}_yahoo_raw.json"
COOKIE_FILE="$DATA_DIR/yahoo_cookie.txt"
mkdir -p "$DATA_DIR"

# Trace logging (same as pipeline/run-framework; writes to assets/traces/<TICKER>_<date>.trace)
source "$SCRIPT_DIR/lib/trace.sh"
init_trace
log_trace "INFO" "fetch_data" "Starting..."

# ============================================
# Step 0: SEC EDGAR (fetch_edgar.sh) – single source for financials and filing URL
# ============================================
echo "📊 Fetching data..."
echo "🔍 SEC EDGAR (company facts + filing URL)..."
if "$SCRIPT_DIR/fetch_edgar.sh" "$TICKER_UPPER" >/dev/null 2>&1; then
    log_trace "INFO" "fetch_data" "SEC EDGAR OK"
else
    log_trace "WARN" "fetch_data" "SEC EDGAR failed or missing; Yahoo/fallbacks will be used"
fi

# Load SEC-derived variables from _edgar.json when present (Yahoo will fill gaps)
EDGAR_REV_Q="" EDGAR_NI_Q="" EDGAR_REV="" EDGAR_NI="" EDGAR_REV_PRIOR="" EDGAR_NI_PRIOR=""
EDGAR_REV_Q_YOY="" EDGAR_FCF="" EDGAR_SHARES_OUT="" EDGAR_SHARES_PRIOR="" EDGAR_SHARES_YOY_PCT=""
EDGAR_REV_LAST_4="[]" EDGAR_GM_LAST_4="[]" EDGAR_LATEST_Q_GM="" EDGAR_RPO_MILLIONS="" EDGAR_DEFERRED_REV="" EARNINGS_URL=""
if [ -f "$EDGAR_JSON" ] && jq -e '.ticker' "$EDGAR_JSON" >/dev/null 2>&1; then
    EDGAR_REV_Q=$(jq -r '.latest_q_revenue // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_NI_Q=$(jq -r '.latest_q_net_income // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_REV=$(jq -r '.latest_fy_revenue // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_NI=$(jq -r '.latest_fy_net_income // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_REV_PRIOR=$(jq -r '.latest_fy_revenue_prior // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_NI_PRIOR=$(jq -r '.latest_fy_net_income_prior // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_REV_Q_YOY=$(jq -r '.revenue_q_yoy // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_FCF=$(jq -r '.fcf // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_SHARES_OUT=$(jq -r '.shares_outstanding // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_SHARES_PRIOR=$(jq -r '.shares_prior // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_SHARES_YOY_PCT=$(jq -r '.shares_yoy_pct // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_REV_LAST_4=$(jq -c '.quarterly_trend.revenue // []' "$EDGAR_JSON" 2>/dev/null || echo "[]")
    EDGAR_GM_LAST_4=$(jq -c '.quarterly_trend.gross_margin // []' "$EDGAR_JSON" 2>/dev/null || echo "[]")
    EDGAR_LATEST_Q_GM=$(jq -r '.latest_q_gross_margin_pct // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_RPO_MILLIONS=$(jq -r '.rpo_millions // empty' "$EDGAR_JSON" 2>/dev/null)
    EDGAR_DEFERRED_REV=$(jq -r '.deferred_revenue_millions // empty' "$EDGAR_JSON" 2>/dev/null)
    EARNINGS_URL=$(jq -r '.latest_10q_url // empty' "$EDGAR_JSON" 2>/dev/null)
    ( echo "$EDGAR_REV_LAST_4" | jq -e . >/dev/null 2>&1 ) || EDGAR_REV_LAST_4="[]"
    ( echo "$EDGAR_GM_LAST_4" | jq -e . >/dev/null 2>&1 ) || EDGAR_GM_LAST_4="[]"
fi

# Yahoo User-Agent (browser-like)
YAHOO_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

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

# Enriched modules: annual + quarterly income/cashflow, balanceSheet for ROIC, plus earningsTrend for guidance/revisions
curl -s -b "$COOKIE_FILE" -H "User-Agent: $YAHOO_AGENT" \
    "https://query2.finance.yahoo.com/v10/finance/quoteSummary/${TICKER_UPPER}?modules=earningsHistory,earningsTrend,assetProfile,defaultKeyStatistics,majorHoldersBreakdown,financialData,incomeStatementHistory,incomeStatementHistoryQuarterly,cashflowStatementHistory,cashflowStatementHistoryQuarterly,balanceSheetHistory,balanceSheetHistoryQuarterly&crumb=${CRUMB}" \
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

# ROIC (Return on Invested Capital): NOPAT / Invested Capital, using income statement [0] and balance sheet [0]
# Tax rate = Tax Provision / Pretax Income; NOPAT = Operating Income * (1 - Tax Rate); Invested Capital = Total Assets - Current Liabilities - Cash
# Yahoo uses balanceSheetStatements (not balanceSheetHistory); prefer annual, fallback to quarterly.
ROIC="N/A"
BS_JSON=""
if jq -e '.quoteSummary.result[0].balanceSheetHistory.balanceSheetStatements[0]' "${Y_RAW}_summary" >/dev/null 2>&1; then
    BS_JSON=$(jq -c '.quoteSummary.result[0].balanceSheetHistory.balanceSheetStatements[0]' "${Y_RAW}_summary" 2>/dev/null)
elif jq -e '.quoteSummary.result[0].balanceSheetHistoryQuarterly.balanceSheetStatements[0]' "${Y_RAW}_summary" >/dev/null 2>&1; then
    BS_JSON=$(jq -c '.quoteSummary.result[0].balanceSheetHistoryQuarterly.balanceSheetStatements[0]' "${Y_RAW}_summary" 2>/dev/null)
fi
if [ -n "$BS_JSON" ] && jq -e '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0]' "${Y_RAW}_summary" >/dev/null 2>&1; then
    TA=$(echo "$BS_JSON" | jq -r '.totalAssets.raw // empty' 2>/dev/null)
    CL=$(echo "$BS_JSON" | jq -r '.totalCurrentLiabilities.raw // .currentLiabilities.raw // empty' 2>/dev/null)
    CASH=$(echo "$BS_JSON" | jq -r '.cash.raw // .cashAndCashEquivalents.raw // 0' 2>/dev/null)
    OP_INC_IS=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].operatingIncome.raw // .quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].incomeFromOperations.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    PRETAX=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].incomeBeforeTax.raw // .quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].pretaxIncome.raw // empty' "${Y_RAW}_summary" 2>/dev/null)
    TAX_PROV=$(jq -r '.quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].taxProvision.raw // .quoteSummary.result[0].incomeStatementHistory.incomeStatementHistory[0].incomeTaxExpense.raw // 0' "${Y_RAW}_summary" 2>/dev/null)
    if [[ "$TA" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [[ "$CL" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [[ "$OP_INC_IS" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        [[ -z "$CASH" || "$CASH" = "null" ]] && CASH=0
        INV_CAP=$(echo "scale=2; $TA - $CL - $CASH" | bc 2>/dev/null)
        if [[ "$INV_CAP" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$INV_CAP > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
            TAX_RATE="0"
            if [[ "$PRETAX" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$PRETAX != 0" | bc 2>/dev/null || echo 0)" = "1" ] && [[ "$TAX_PROV" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                TAX_RATE=$(echo "scale=4; $TAX_PROV / $PRETAX" | bc 2>/dev/null || echo "0")
            fi
            NOPAT=$(echo "scale=2; $OP_INC_IS * (1 - $TAX_RATE)" | bc 2>/dev/null)
            if [[ "$NOPAT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                ROIC_RAW=$(echo "scale=4; $NOPAT / $INV_CAP" | bc 2>/dev/null)
                if [[ "$ROIC_RAW" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                    ROIC_PCT=$(echo "scale=2; $ROIC_RAW * 100" | bc 2>/dev/null)
                    ROIC="${ROIC_PCT}%"
                    log_trace "INFO" "fetch_data" "ROIC computed: $ROIC (NOPAT/Invested Capital)"
                fi
            fi
        fi
    fi
fi

# Shares outstanding (proxy for dilution / buybacks)
SHARES_OUT=$(jq -r '.quoteSummary.result[0].defaultKeyStatistics.sharesOutstanding.raw // .quoteSummary.result[0].defaultKeyStatistics.sharesOutstanding // "N/A"' "${Y_RAW}_summary" 2>/dev/null || echo "N/A")
SHARES_PRIOR="N/A"
SHARES_YOY_PCT="N/A"

# ============================================
# Overlay: prefer SEC EDGAR values when present (from fetch_edgar.sh)
# ============================================
[ -n "$EDGAR_REV_Q" ] && CURR_REV_Q="$EDGAR_REV_Q"
[ -n "$EDGAR_NI_Q" ] && CURR_NI_Q="$EDGAR_NI_Q"
# Annual rev/ni: use EDGAR only when Yahoo did not provide (fill gaps, don't overwrite)
USED_EDGAR_REV=""
USED_EDGAR_NI=""
if [ -n "$EDGAR_REV" ] && { [ "$CURR_REV" = "N/A" ] || [ -z "$CURR_REV" ]; }; then CURR_REV="$EDGAR_REV"; REV="$EDGAR_REV"; USED_EDGAR_REV=1; fi
if [ -n "$EDGAR_NI" ] && { [ "$CURR_NI" = "N/A" ] || [ -z "$CURR_NI" ]; }; then CURR_NI="$EDGAR_NI"; NI="$EDGAR_NI"; USED_EDGAR_NI=1; fi
if [ -n "$USED_EDGAR_REV" ] && [ -n "$EDGAR_REV_PRIOR" ] && [ -n "$EDGAR_REV" ] && [ "$EDGAR_REV_PRIOR" != "0" ]; then
    REV_YOY=$(echo "scale=4; ($EDGAR_REV - $EDGAR_REV_PRIOR) * 100 / $EDGAR_REV_PRIOR" | bc 2>/dev/null || echo "$REV_YOY")
fi
if [ -n "$USED_EDGAR_NI" ] && [ -n "$EDGAR_NI_PRIOR" ] && [ -n "$EDGAR_NI" ] && [ "$EDGAR_NI_PRIOR" != "0" ]; then
    NI_YOY=$(echo "scale=4; ($EDGAR_NI - $EDGAR_NI_PRIOR) * 100 / $EDGAR_NI_PRIOR" | bc 2>/dev/null || echo "$NI_YOY")
fi
[ -n "$EDGAR_REV_Q_YOY" ] && REV_Q_YOY="$EDGAR_REV_Q_YOY"
[ -n "$EDGAR_FCF" ] && FCF="$EDGAR_FCF"
[ -n "$EDGAR_SHARES_OUT" ] && SHARES_OUT="$EDGAR_SHARES_OUT"
[ -n "$EDGAR_SHARES_PRIOR" ] && SHARES_PRIOR="$EDGAR_SHARES_PRIOR"
[ -n "$EDGAR_SHARES_YOY_PCT" ] && SHARES_YOY_PCT="$EDGAR_SHARES_YOY_PCT"
[ -n "$EDGAR_REV_LAST_4" ] && [ "$EDGAR_REV_LAST_4" != "[]" ] && REV_LAST_4="$EDGAR_REV_LAST_4"
[ -n "$EDGAR_GM_LAST_4" ] && [ "$EDGAR_GM_LAST_4" != "[]" ] && GM_LAST_4="$EDGAR_GM_LAST_4"
[ -n "$EDGAR_LATEST_Q_GM" ] && [ "$EDGAR_LATEST_Q_GM" != "null" ] && LATEST_Q_GROSS_MARGIN_PCT="$EDGAR_LATEST_Q_GM"
if [ -n "$EDGAR_RPO_MILLIONS" ] && [[ "$EDGAR_RPO_MILLIONS" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    SEC_RPO=$(echo "scale=0; $EDGAR_RPO_MILLIONS * 1000000" | bc 2>/dev/null || echo "$EDGAR_RPO_MILLIONS")
fi
if [ -n "$EDGAR_DEFERRED_REV" ] && [[ "$EDGAR_DEFERRED_REV" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    SEC_DEFERRED_REV=$(echo "scale=0; $EDGAR_DEFERRED_REV * 1000000" | bc 2>/dev/null || echo "$EDGAR_DEFERRED_REV")
fi
REV="${REV:-$CURR_REV}"
NI="${NI:-$CURR_NI}"

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

# When Yahoo did not provide quarterly gross margin, fill with annual so trend is visible
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

# Earnings URL is set from SEC EDGAR (fetch_edgar.sh) in Step 0; no discovery or parser.

# Margin inflection: compare latest-q margin to annual when available
if [ "$MARGIN_INFLECTION" = "false" ] && [ -n "$LATEST_Q_GROSS_MARGIN_PCT" ] && [ "$LATEST_Q_GROSS_MARGIN_PCT" != "N/A" ]; then
    ANNUAL_PCT=""
    if [[ "$GROSS_MARGIN" =~ ^([0-9.]+)%?$ ]]; then ANNUAL_PCT="${BASH_REMATCH[1]}"; fi
    if [[ -n "$ANNUAL_PCT" && "$ANNUAL_PCT" =~ ^[0-9.]+$ ]] && [[ "$LATEST_Q_GROSS_MARGIN_PCT" =~ ^[0-9.]+$ ]]; then
        PP_DIFF=$(echo "scale=2; $LATEST_Q_GROSS_MARGIN_PCT - $ANNUAL_PCT" | bc 2>/dev/null || echo "0")
        GT_150=$(echo "scale=0; $PP_DIFF > 1.5" | bc 2>/dev/null || echo "0")
        [ "${GT_150:-0}" = "1" ] && MARGIN_INFLECTION="true"
    fi
fi

# Placeholders for optional fields (no longer parsed from earnings HTML)
LATEST_Q_GAAP_GM_PCT=""
LATEST_Q_NON_GAAP_GM_PCT=""
RPO_MILLIONS=""
RPO_YOY_PCT=""
FULL_YEAR_NON_GAAP_NET_INCOME_MILLIONS=""
COMPUTE_AND_AI_REVENUE_GROWTH_YOY_PCT=""
FULL_YEAR_GUIDANCE_EPS_LOW=""
FULL_YEAR_GUIDANCE_EPS_HIGH=""

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

# RPO from SEC EDGAR (set in overlay from _edgar.json). SEC_RPO is in dollars.
if [[ "${SEC_RPO:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    RPO_DOLLARS=$(awk -v n="$SEC_RPO" 'BEGIN { printf "%.0f", n }')
    RPO_MILLIONS=$(format_millions "$SEC_RPO")
    RPO_SOURCE="sec_edgar"
    RPO_QUALITY_STATUS="present_unchecked"
    if [[ "$CURR_REV" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [ "$(echo "$CURR_REV > 0" | bc 2>/dev/null || echo 0)" = "1" ]; then
        RPO_COVERAGE_RATIO=$(awk -v rpo="$RPO_DOLLARS" -v rev="$CURR_REV" 'BEGIN { printf "%.4f", rpo / rev }')
        RPO_QUALITY_STATUS="valid"
        if [ "$SECTOR_TYPE" = "TECH" ] && [ "$(echo "$RPO_COVERAGE_RATIO < 0.01" | bc 2>/dev/null || echo 0)" = "1" ]; then
            RPO_QUALITY_STATUS="suspect_too_small_vs_revenue"
        fi
    fi
    log_trace "INFO" "fetch_data" "RPO from SEC EDGAR"
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
# Step 4: Final JSON Compilation (with quarterly_trend, sector_context, nested edgar)
# ============================================
# Nest full EDGAR payload under .edgar (single-file output; _edgar.json removed after)
EDGAR_OBJ="null"
[ -f "$EDGAR_JSON" ] && jq -e '.ticker' "$EDGAR_JSON" >/dev/null 2>&1 && EDGAR_OBJ=$(jq -c . "$EDGAR_JSON" 2>/dev/null) || true
[ -z "$EDGAR_OBJ" ] && EDGAR_OBJ="null"

echo "💾 Compiling Unified Dataset..."
jq -n \
    --argjson edgar "$EDGAR_OBJ" \
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
    --arg roic "$ROIC" \
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
    --arg earnings_url "${EARNINGS_URL:-}" \
    '{
        ticker: $ticker,
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        company_profile: { name: $ticker, description: $desc },
        earnings_url: (if $earnings_url != "" then $earnings_url else null end),
        sector_context: { sector: $sector, category: $sector_type, power_metrics: $sector_data },
        financial_metrics: { 
            revenue: $rev, 
            net_income: $ni, 
            roe: $roe,
            gross_margin: $gross_margin,
            operating_margin: $op_margin,
            roa: $roa,
            roic: (if $roic != "" and $roic != "N/A" then $roic else null end),
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
        momentum: { earnings_surprises: $surprise },
        edgar: $edgar
    }' > "$DATA_FILE"

# Remove standalone EDGAR file; data is now nested under .edgar in _data.json
rm -f "$EDGAR_JSON"

# Cleanup (set FETCH_KEEP_YAHOO=1 to keep Yahoo summary for debugging)
if [ "${FETCH_KEEP_YAHOO:-0}" != "1" ]; then
    rm -f "${Y_RAW}_quote" "${Y_RAW}_summary" "$COOKIE_FILE"
fi
log_trace "INFO" "fetch_data" "Complete | $DATA_FILE"
echo "✅ Data ready: $DATA_FILE"