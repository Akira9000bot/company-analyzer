#!/bin/bash
# fetch_edgar.sh - Fetch latest 10-K and 10-Q financial data and filing URL from SEC EDGAR.
# Replaces earnings_url discovery with a single, reliable SEC-based source for filing docs and numbers.
#
# CONSTRAINT 1: SEC requires a compliant User-Agent or they block the IP.
# CONSTRAINT 2: Do not exceed 10 requests per second (we use sleep 0.2 between calls).
#
# Usage: ./fetch_edgar.sh <TICKER>
# Output: .cache/data/{TICKER}_edgar.json (when run standalone).
# When run from fetch_data.sh, this file is merged into {TICKER}_data.json under key "edgar" and then removed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKER_UPPER=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
[ -z "$TICKER_UPPER" ] && { echo "Usage: $0 <TICKER>"; exit 1; }

DATA_DIR="$(dirname "$SCRIPT_DIR")/.cache/data"
OUTPUT_FILE="$DATA_DIR/${TICKER_UPPER}_edgar.json"
mkdir -p "$DATA_DIR"

# MANDATORY: SEC blocks generic/missing User-Agent
SEC_USER_AGENT="AnalyzeScript/1.0 (company-analyzer@gmail.com)"
[ -n "${SEC_EDGAR_USER_AGENT:-}" ] && SEC_USER_AGENT="$SEC_EDGAR_USER_AGENT"

sec_curl() {
    curl -sL -H "User-Agent: $SEC_USER_AGENT" --connect-timeout 15 --max-time 30 "$@"
}

# Rate limit: 10 req/s max → sleep 0.2 between consecutive API calls
rate_sleep() { sleep 0.2; }

# ============================================
# STEP 1: Ticker → CIK mapping
# ============================================
echo "📋 Step 1: Resolving ticker to CIK..."
TICKERS_JSON=$(sec_curl "https://www.sec.gov/files/company_tickers.json") || true
if ! echo "$TICKERS_JSON" | jq -e '.' >/dev/null 2>&1; then
    echo "ERROR: Failed to fetch or parse company_tickers.json" >&2
    exit 1
fi

CIK_RAW=$(echo "$TICKERS_JSON" | jq -r --arg t "$TICKER_UPPER" '[.[] | select(.ticker == $t) | .cik_str] | first // empty')
if [ -z "$CIK_RAW" ] || [ "$CIK_RAW" = "null" ]; then
    echo "ERROR: Ticker $TICKER_UPPER not found in SEC company_tickers.json" >&2
    exit 1
fi

# Pad CIK to exactly 10 digits
PADDED_CIK=$(printf "%010d" "$((10#$CIK_RAW))")
echo "   CIK: $PADDED_CIK"

rate_sleep

# ============================================
# STEP 2: Fetch Company Facts (XBRL numbers)
# ============================================
echo "📊 Step 2: Fetching company facts..."
FACTS_JSON=$(sec_curl "https://data.sec.gov/api/xbrl/companyfacts/CIK${PADDED_CIK}.json") || true
if ! echo "$FACTS_JSON" | jq -e '.facts."us-gaap"' >/dev/null 2>&1; then
    echo "ERROR: Failed to fetch or parse companyfacts for CIK $PADDED_CIK" >&2
    exit 1
fi

# ============================================
# STEP 3 & 4: GAAP fallback cascade + latest 10-K / 10-Q values
# ============================================
# Helper: get latest value for a given form (10-Q or 10-K) from a GAAP key path (e.g. .facts."us-gaap".Revenues.units.USD)
# Returns the .val of the most recent filing by .end date.
get_latest_val() {
    local form="$1"  # "10-Q" or "10-K"
    local key="$2"   # e.g. Revenues
    # Use // [] so missing GAAP key does not make jq iterate over null (exit 5)
    echo "$FACTS_JSON" | jq -r --arg f "$form" --arg k "$key" '
        (.facts."us-gaap"[$k].units.USD // [])
        | map(select(.form == $f))
        | sort_by(.end | split("-") | map(tonumber))
        | last
        | .val // empty
    ' 2>/dev/null
}

# Revenue fallback array (in order)
REVENUE_KEYS=(Revenues SalesRevenueNet RevenueFromContractWithCustomerExcludingAssessedTax RevenuesNetOfYearToDateBillingsInExcessOfCostsOnUncompletedContracts)
# Net Income fallback array
NETINCOME_KEYS=(NetIncomeLoss ProfitLoss)
# Operating Income (single key per spec)
OPINCOME_KEYS=(OperatingIncomeLoss)

latest_q_revenue=""
latest_q_net_income=""
latest_fy_revenue=""

for key in "${REVENUE_KEYS[@]}"; do
    latest_q_revenue=$(get_latest_val "10-Q" "$key")
    [ -n "$latest_q_revenue" ] && break
done
for key in "${REVENUE_KEYS[@]}"; do
    latest_fy_revenue=$(get_latest_val "10-K" "$key")
    [ -n "$latest_fy_revenue" ] && break
done
for key in "${NETINCOME_KEYS[@]}"; do
    latest_q_net_income=$(get_latest_val "10-Q" "$key")
    [ -n "$latest_q_net_income" ] && break
done

latest_q_operating_income=""
for key in "${OPINCOME_KEYS[@]}"; do
    latest_q_operating_income=$(get_latest_val "10-Q" "$key")
    [ -n "$latest_q_operating_income" ] && break
done

# Annual net income (10-K) for YoY and data.json
latest_fy_net_income=""
for key in "${NETINCOME_KEYS[@]}"; do
    latest_fy_net_income=$(get_latest_val "10-K" "$key")
    [ -n "$latest_fy_net_income" ] && break
done

# Optional extraction (may fail for some tickers; do not exit script)
set +e
# Revenue Q YoY: (latest 10-Q rev - same quarter prior year 10-Q rev) / prior * 100. Need 5+ 10-Q entries.
revenue_q_yoy=""
for key in "${REVENUE_KEYS[@]}"; do
    rev_pair=$(echo "$FACTS_JSON" | jq -r --arg k "$key" '
        (.facts."us-gaap"[$k].units.USD // []) | map(select(.form == "10-Q")) | sort_by(.end | split("-") | map(tonumber))
        | if length >= 5 then [(.[-5].val | tostring), (.[-1].val | tostring)] | join(" ") else empty end
    ' 2>/dev/null)
    if [ -n "$rev_pair" ]; then
        prev_rev=$(echo "$rev_pair" | awk '{print $1}')
        curr_rev=$(echo "$rev_pair" | awk '{print $2}')
        if [ -n "$prev_rev" ] && [ -n "$curr_rev" ] && [ "$prev_rev" != "0" ]; then
            revenue_q_yoy=$(echo "scale=4; ($curr_rev - $prev_rev) * 100 / $prev_rev" | bc 2>/dev/null || echo "")
        fi
        break
    fi
done

# FCF: OpCF - Capex (latest annual from 10-K)
fcf=""
OPCF_KEYS=(NetCashProvidedByUsedInOperatingActivities NetCashProvidedByUsedInOperatingActivitiesContinuingOperations)
CAPEX_KEYS=(PaymentsToAcquirePropertyPlantAndEquipment PaymentsToAcquireProductiveAssets CapitalExpendituresPaid)
opcf=""
for key in "${OPCF_KEYS[@]}"; do
    opcf=$(get_latest_val "10-K" "$key")
    [ -n "$opcf" ] && break
done
[ -z "$opcf" ] && for key in "${OPCF_KEYS[@]}"; do opcf=$(get_latest_val "10-Q" "$key"); [ -n "$opcf" ] && break; done
capex=""
for key in "${CAPEX_KEYS[@]}"; do
    capex=$(get_latest_val "10-K" "$key")
    [ -n "$capex" ] && break
done
[ -z "$capex" ] && for key in "${CAPEX_KEYS[@]}"; do capex=$(get_latest_val "10-Q" "$key"); [ -n "$capex" ] && break; done
if [ -n "$opcf" ] && [ -n "$capex" ]; then
    # Capex is typically negative in cash flow
    fcf=$(echo "scale=0; $opcf + $capex" | bc 2>/dev/null || echo "")
fi

# Shares: two most recent (any form) for YoY. Units can be "shares" or "pure".
shares_out=""
shares_prior=""
shares_yoy_pct=""
SHARES_KEYS=(CommonStockSharesOutstanding WeightedAverageNumberOfSharesOutstandingBasic CommonStockSharesIssued)
for key in "${SHARES_KEYS[@]}"; do
    two=""
    for u in shares pure; do
        two=$(echo "$FACTS_JSON" | jq -r --arg k "$key" --arg u "$u" '
            (.facts."us-gaap"[$k].units[$u] // [])
            | if type == "array" and length >= 2 then sort_by(.end | split("-") | map(tonumber)) | "\(.[-2].val) \(.[-1].val)" else empty end
        ' 2>/dev/null)
        [ -n "$two" ] && break
    done
    if [ -n "$two" ]; then
        shares_prior=$(echo "$two" | awk '{print $1}')
        shares_out=$(echo "$two" | awk '{print $2}')
        if [ -n "$shares_prior" ] && [ -n "$shares_out" ] && [ "$shares_prior" != "0" ]; then
            shares_yoy_pct=$(echo "scale=2; ($shares_out - $shares_prior) * 100 / $shares_prior" | bc 2>/dev/null || echo "")
        fi
        break
    fi
done

# Last 4 quarters revenue and gross margin (10-Q only)
rev_last_4="[]"
gm_last_4="[]"
for key in "${REVENUE_KEYS[@]}"; do
    rev_last_4=$(echo "$FACTS_JSON" | jq -c --arg k "$key" '
        (.facts."us-gaap"[$k].units.USD // []) | map(select(.form == "10-Q")) | sort_by(.end | split("-") | map(tonumber))
        | .[-4:] | [.[].val]
    ' 2>/dev/null)
    [ -n "$rev_last_4" ] && [ "$rev_last_4" != "[]" ] && break
done
# Gross margin last 4 Q: (Revenue - CostOfRevenue) / Revenue * 100. Cost keys: CostOfRevenue, CostOfGoodsAndServicesSold
COST_KEYS=(CostOfRevenue CostOfGoodsAndServicesSold)
for rev_key in "${REVENUE_KEYS[@]}"; do
    for cost_key in "${COST_KEYS[@]}"; do
        gm_last_4=$(echo "$FACTS_JSON" | jq -c --arg rk "$rev_key" --arg ck "$cost_key" '
            ((.facts."us-gaap"[$rk].units.USD // []) | map(select(.form == "10-Q")) | sort_by(.end | split("-") | map(tonumber)) | .[-4:]) as $rq |
            ((.facts."us-gaap"[$ck].units.USD // []) | map(select(.form == "10-Q")) | sort_by(.end | split("-") | map(tonumber)) | .[-4:]) as $cq |
            if ($rq | length) == 4 and ($cq | length) >= 4 then
                [range(4) | $rq[.].val as $rv | $cq[.].val as $cv | if $rv != null and $rv != 0 and $cv != null then (($rv - $cv) / $rv) * 100 else null end]
            else [] end
        ' 2>/dev/null)
        [ -n "$gm_last_4" ] && [ "$gm_last_4" != "[]" ] && break 2
    done
done

# Latest Q gross margin % (from latest 10-Q revenue and cost)
latest_q_gross_margin_pct=""
if [ -n "$latest_q_revenue" ] && [ "$latest_q_revenue" != "0" ]; then
    for cost_key in "${COST_KEYS[@]}"; do
        cv=$(get_latest_val "10-Q" "$cost_key")
        if [ -n "$cv" ]; then
            latest_q_gross_margin_pct=$(echo "scale=2; ($latest_q_revenue - $cv) * 100 / $latest_q_revenue" | bc 2>/dev/null || echo "")
            break
        fi
    done
fi

# RPO and deferred revenue (latest, for TECH sector power_metrics)
rpo_millions=""
deferred_revenue=""
RPO_KEYS=(RevenueRemainingPerformanceObligation ContractWithCustomerLiability)
DEF_KEYS=(DeferredRevenue ContractWithCustomerLiability DeferredRevenueCurrent DeferredRevenueNoncurrent)
for key in "${RPO_KEYS[@]}"; do
    val=$(echo "$FACTS_JSON" | jq -r --arg k "$key" '(.facts."us-gaap"[$k].units.USD // []) | sort_by(.end | split("-") | map(tonumber)) | last | .val // empty' 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ]; then
        rpo_millions=$(echo "scale=1; $val / 1000000" | bc 2>/dev/null || echo "")
        break
    fi
done
for key in "${DEF_KEYS[@]}"; do
    val=$(echo "$FACTS_JSON" | jq -r --arg k "$key" '(.facts."us-gaap"[$k].units.USD // []) | sort_by(.end | split("-") | map(tonumber)) | last | .val // empty' 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ]; then
        deferred_revenue=$(echo "scale=1; $val / 1000000" | bc 2>/dev/null || echo "")
        break
    fi
done

# Prior-year 10-K revenue and net income (for annual YoY in fetch_data)
latest_fy_revenue_prior=""
latest_fy_net_income_prior=""
for key in "${REVENUE_KEYS[@]}"; do
    latest_fy_revenue_prior=$(echo "$FACTS_JSON" | jq -r --arg k "$key" '
        (.facts."us-gaap"[$k].units.USD // []) | map(select(.form == "10-K")) | sort_by(.end | split("-") | map(tonumber)) | if length >= 2 then .[-2].val else empty end
    ' 2>/dev/null)
    [ -n "$latest_fy_revenue_prior" ] && break
done
for key in "${NETINCOME_KEYS[@]}"; do
    latest_fy_net_income_prior=$(echo "$FACTS_JSON" | jq -r --arg k "$key" '
        (.facts."us-gaap"[$k].units.USD // []) | map(select(.form == "10-K")) | sort_by(.end | split("-") | map(tonumber)) | if length >= 2 then .[-2].val else empty end
    ' 2>/dev/null)
    [ -n "$latest_fy_net_income_prior" ] && break
done
set -e

rate_sleep

# ============================================
# STEP 5: Submissions metadata → document URL
# ============================================
echo "📎 Step 3: Fetching submissions (filing URL)..."
SUBMISSIONS_JSON=$(sec_curl "https://data.sec.gov/submissions/CIK${PADDED_CIK}.json") || true
if ! echo "$SUBMISSIONS_JSON" | jq -e '.filings.recent' >/dev/null 2>&1; then
    echo "WARN: Failed to fetch submissions; latest_filing_url will be null" >&2
    latest_10q_url=""
else
    # filings.recent is columnar: .form[i], .accessionNumber[i], .primaryDocument[i]
    # Find first index where form is 10-Q or 10-K, then get accessionNumber and primaryDocument at that index
    FIRST_INDEX=$(echo "$SUBMISSIONS_JSON" | jq -r '
        .filings.recent.form
        | to_entries
        | map(select(.value == "10-Q" or .value == "10-K"))
        | .[0].key // empty
    ' 2>/dev/null)
    if [ -n "$FIRST_INDEX" ] && [ "$FIRST_INDEX" != "null" ]; then
        ACCESSION=$(echo "$SUBMISSIONS_JSON" | jq -r --argjson i "$FIRST_INDEX" '.filings.recent.accessionNumber[$i] // empty')
        PRIMARY_DOC=$(echo "$SUBMISSIONS_JSON" | jq -r --argjson i "$FIRST_INDEX" '.filings.recent.primaryDocument[$i] // empty')
        if [ -n "$ACCESSION" ] && [ "$ACCESSION" != "null" ] && [ -n "$PRIMARY_DOC" ] && [ "$PRIMARY_DOC" != "null" ]; then
            CLEAN_ACCESSION=$(echo "$ACCESSION" | tr -d '-')
            RAW_CIK=$((10#$PADDED_CIK))
            latest_10q_url="https://www.sec.gov/Archives/edgar/data/${RAW_CIK}/${CLEAN_ACCESSION}/${PRIMARY_DOC}"
        else
            latest_10q_url=""
        fi
    else
        latest_10q_url=""
    fi
fi

# ============================================
# Write output JSON
# ============================================
echo "💾 Writing $OUTPUT_FILE ..."
# Ensure rev_last_4 and gm_last_4 are valid JSON arrays (set -e safe: subshell so jq failure doesn't exit)
[ -z "$rev_last_4" ] && rev_last_4="[]"
[ -z "$gm_last_4" ] && gm_last_4="[]"
( echo "$rev_last_4" | jq -e . >/dev/null 2>&1 ) || rev_last_4="[]"
( echo "$gm_last_4" | jq -e . >/dev/null 2>&1 ) || gm_last_4="[]"

jq -n \
    --arg ticker "$TICKER_UPPER" \
    --arg cik "$PADDED_CIK" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lq_rev "${latest_q_revenue:-}" \
    --arg lq_ni "${latest_q_net_income:-}" \
    --arg lfy_rev "${latest_fy_revenue:-}" \
    --arg lfy_ni "${latest_fy_net_income:-}" \
    --arg lq_oi "${latest_q_operating_income:-}" \
    --arg url "${latest_10q_url:-}" \
    --arg rqyoy "${revenue_q_yoy:-}" \
    --arg fcf "${fcf:-}" \
    --arg so "${shares_out:-}" \
    --arg sp "${shares_prior:-}" \
    --arg syp "${shares_yoy_pct:-}" \
    --arg lqgm "${latest_q_gross_margin_pct:-}" \
    --arg rpo "${rpo_millions:-}" \
    --arg defrev "${deferred_revenue:-}" \
    --arg lfy_rev_prior "${latest_fy_revenue_prior:-}" \
    --arg lfy_ni_prior "${latest_fy_net_income_prior:-}" \
    --argjson rev4 "$rev_last_4" \
    --argjson gm4 "$gm_last_4" \
    '{
        ticker: $ticker,
        cik: $cik,
        timestamp: $ts,
        source: "SEC EDGAR",
        latest_q_revenue: (if $lq_rev != "" then ($lq_rev | tonumber) else null end),
        latest_q_net_income: (if $lq_ni != "" then ($lq_ni | tonumber) else null end),
        latest_fy_revenue: (if $lfy_rev != "" then ($lfy_rev | tonumber) else null end),
        latest_fy_net_income: (if $lfy_ni != "" then ($lfy_ni | tonumber) else null end),
        latest_fy_revenue_prior: (if $lfy_rev_prior != "" then ($lfy_rev_prior | tonumber) else null end),
        latest_fy_net_income_prior: (if $lfy_ni_prior != "" then ($lfy_ni_prior | tonumber) else null end),
        latest_q_operating_income: (if $lq_oi != "" then ($lq_oi | tonumber) else null end),
        latest_10q_url: (if $url != "" then $url else null end),
        revenue_q_yoy: (if $rqyoy != "" then ($rqyoy | tonumber) else null end),
        fcf: (if $fcf != "" then ($fcf | tonumber) else null end),
        shares_outstanding: (if $so != "" then ($so | tonumber) else null end),
        shares_prior: (if $sp != "" then ($sp | tonumber) else null end),
        shares_yoy_pct: (if $syp != "" then $syp else null end),
        latest_q_gross_margin_pct: (if $lqgm != "" then $lqgm else null end),
        rpo_millions: (if $rpo != "" then ($rpo | tonumber) else null end),
        deferred_revenue_millions: (if $defrev != "" then ($defrev | tonumber) else null end),
        quarterly_trend: { revenue: $rev4, gross_margin: $gm4 }
    }' > "$OUTPUT_FILE"

echo "✅ Done: $OUTPUT_FILE"
echo "   latest_q_revenue: ${latest_q_revenue:-null}"
echo "   latest_fy_revenue: ${latest_fy_revenue:-null}"
echo "   latest_10q_url: ${latest_10q_url:-null}"
