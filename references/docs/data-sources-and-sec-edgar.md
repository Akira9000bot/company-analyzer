# Data Sources vs SEC EDGAR-Only

Can we build the same `*_data.json` (e.g. `AAPL_data.json`) using **only** the new SEC EDGAR script (`fetch_edgar.sh`) and SEC APIs?

## Short answer

**No.** SEC EDGAR can fill **most financial statement and filing fields**, but the current `*_data.json` also depends on **Yahoo** (and sometimes Alpha Vantage) for **quotes, analyst data, and sentiment**. You need at least one **quote/sentiment** source alongside SEC.

## Field-by-field: where it comes from today vs SEC-only

| Section | Field | Current source | SEC EDGAR only? |
|--------|--------|----------------|-----------------|
| **company_profile** | description | Yahoo `assetProfile.longBusinessSummary` | ❌ No (SEC has company name only in submissions) |
| **sector_context** | sector, category | Yahoo `assetProfile.sector` | ❌ No (SEC has SIC in submissions, not sector/category) |
| **sector_context** | power_metrics (RPO, deferred rev, etc.) | Earnings parser or SEC companyfacts | ✅ Yes (companyfacts has RPO, DeferredRevenue, etc.) |
| **financial_metrics** | revenue, net_income (annual) | Yahoo or SEC companyfacts | ✅ Yes |
| **financial_metrics** | revenue_q, net_income_q | Yahoo or SEC companyfacts | ✅ Yes (`fetch_edgar` already) |
| **financial_metrics** | revenue_yoy, net_income_yoy | Derived from annual | ✅ Yes (from SEC annual) |
| **financial_metrics** | revenue_q_yoy | Yahoo or Alpha Vantage | ✅ Yes (from SEC last two 10-Q values) |
| **financial_metrics** | fcf | Yahoo cashflow or SEC (OpCF − Capex) | ✅ Yes (companyfacts) |
| **financial_metrics** | shares_outstanding, shares_prior, shares_yoy_pct | Yahoo or SEC companyfacts | ✅ Yes (companyfacts) |
| **financial_metrics** | roe, roa, gross_margin, operating_margin, roic | Yahoo financialData or computed | ✅ Yes if we add more SEC tags (equity, assets, cost of revenue) and compute |
| **financial_metrics** | latest_q_gross_margin_pct | Yahoo quarterly or earnings parser | ✅ Yes (Revenue − CostOfRevenue from SEC, then compute %) |
| **financial_metrics** | RPO, rpo_*, full_year_non_gaap_*, etc. | Earnings parser or SEC | ✅ Yes (SEC companyfacts) |
| **financial_metrics** | quarterly_trend (revenue, gross_margin last 4 Q) | Yahoo or earnings | ✅ Yes (companyfacts history) |
| **valuation** | current_price, market_cap | Yahoo quote | ❌ **No** — need a quote API |
| **valuation** | target_mean/high/low (analyst targets) | Yahoo financialData | ❌ **No** — need analyst data |
| **valuation** | guidance_eps, guidance_eps_low/high | Yahoo earningsTrend | ❌ **No** — analyst consensus |
| **valuation** | internal_guidance_target, primary_valuation_anchor | Derived from guidance + growth | ❌ No (depends on guidance) |
| **valuation** | institutional_ownership_pct, institutions_count | Yahoo majorHoldersBreakdown | ❌ **No** |
| **momentum** | earnings_surprises (beat %) | Yahoo earningsHistory | ❌ **No** |

## What SEC EDGAR can and cannot do

- **SEC can provide (with current or extended `fetch_edgar`):**
  - Ticker → CIK, latest 10-Q/10-K document URL.
  - Revenue, net income, operating income (annual and latest quarter) with GAAP fallback.
  - Last 4 quarters revenue (and gross margin if we add CostOfRevenue) for `quarterly_trend`.
  - FCF (from operating cash flow and capex in companyfacts).
  - Shares outstanding (and prior for YoY).
  - RPO, deferred revenue, and other us-gaap metrics.
  - ROE/ROA/ROIC if we pull balance sheet and compute.

- **SEC cannot provide (need Yahoo or another source):**
  - **Stock price and market cap.**
  - **Analyst targets** (mean/high/low).
  - **Earnings guidance** (consensus EPS).
  - **Earnings surprise** (beat %).
  - **Institutional ownership.**
  - **Company description** (only company name from submissions).
  - **Sector/category** (SEC has SIC, not your TECH/RETAIL/etc. mapping).

## Practical approach

- **Option A – Keep hybrid (current design):**  
  Use **Yahoo** (and AV fallback) for quote, analyst data, description, sector, and sentiment. Use **SEC** (e.g. `fetch_edgar` + companyfacts) for **filing URL**, authoritative revenue/income/FCF/shares, and optional RPO/trends. This gives you the same `*_data.json` with SEC improving quality of financials and replacing earnings URL discovery.

- **Option B – SEC-only for a “financials-only” payload:**  
  Extend `fetch_edgar` (and maybe one more script) to pull everything SEC offers (quarterly trend, FCF, shares, RPO, margins, ROE/ROA/ROIC). Output a **separate** JSON (e.g. `{TICKER}_edgar_data.json`) that has the same **financial_metrics** (and sector_context power_metrics) shape as `*_data.json`, but with **valuation** and **momentum** set to `null` or omitted. Then a **lightweight quote step** (Yahoo or other) would only need to add: price, market_cap, analyst targets, guidance, institutional ownership, earnings_surprises. That keeps “one source of truth” for numbers (SEC) and minimizes reliance on Yahoo for fundamentals.

- **Option C – Replace earnings URL only:**  
  Keep current `fetch_data.sh` flow; run `fetch_edgar.sh`, read SEC output during build, merge into the main pipeline (earnings URL + financial overlay), and nest the full EDGAR payload under `*_data.json` key `edgar`. No standalone `*_edgar.json` is persisted.

Summary: **You cannot fill the *entire* current `*_data.json` from SEC EDGAR alone**, but you can get **all or most financial and filing data** from SEC and use a **small quote/sentiment** source for the rest.
