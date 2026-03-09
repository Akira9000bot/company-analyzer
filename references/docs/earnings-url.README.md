# Latest-Quarter Gross Margin from Earnings Press Releases

Many companies report **GAAP** and **Non-GAAP gross margin** for the most recent quarter in their earnings press release (e.g. "Q4 2025 GAAP gross margin 61.4%, Non-GAAP 64.0%"). Yahoo and Alpha Vantage often only provide annual or GAAP figures, and quarterly gross margin may be missing or stale. To get the **most recent quarter** and **non-GAAP** values into the data file, the pipeline can parse a known earnings-release URL.

## How the URL is chosen

`fetch_data.sh` uses the earnings URL in this order:

1. **Environment variable**  
   If `EARNINGS_URL` is set, that URL is used (overrides file and discovery).

2. **Per-ticker file**  
   If `.cache/data/<TICKER>_earnings_url.txt` exists and contains a URL, that is used.

3. **Auto-discovery**  
   If neither is set, the script tries to discover a URL from the company's investor relations site. It first checks **`references/earnings_url_overrides.json`**: if the ticker is listed, that **IR base URL** (e.g. `https://investor.fb.com` for META) is tried so discovery can find the earnings link on non-standard IR sites. Then it derives common IR bases from Yahoo's `assetProfile.website` (e.g. `https://investors.<domain>`, `https://ir.<domain>`), fetches each IR news page, and picks the first link that looks like an earnings or press-release page. If a URL is found, it is **saved** to `.cache/data/<TICKER>_earnings_url.txt` for this run and future runs.

**Overrides for non-standard IR:** Add tickers to `references/earnings_url_overrides.json` in either form:

- **Base URL** – Discovery fetches that IR base first (e.g. `https://investor.atmeta.com`) and picks the first earnings link. Use when the company’s IR isn’t at `investors.<domain>`.
- **Full earnings URL** – Used directly; discovery is skipped. Use for a known press-release URL (update after each earnings report).

```json
{ "META": "https://investor.atmeta.com/investor-news/press-release-details/2026/Meta-Reports-Fourth-Quarter-and-Full-Year-2025-Results/default.aspx" }
```

To force a specific URL (e.g. after a new earnings report), set `EARNINGS_URL` or create/update the file:

- Path: `.cache/data/<TICKER>_earnings_url.txt`  
- Example: `.cache/data/FSLY_earnings_url.txt` with one line:  
  `https://investors.fastly.com/news/news-details/2026/Fastly-Announces-Both-Record-Fourth-Quarter-and-Full-Year-2025-Financial-Results/default.aspx`

When the URL is set, `fetch_data.sh` runs `scripts/lib/parse_earnings_gross_margin.sh`, which fetches the page, strips HTML, and extracts:

| Data | JSON field | Description |
|------|------------|-------------|
| GAAP / Non-GAAP gross margin (latest quarter) | `latest_q_gaap_gross_margin_pct`, `latest_q_non_gaap_gross_margin_pct` | First percentage after "GAAP gross margin" and "Non-GAAP gross margin" in the table. |
| RPO (Remaining Performance Obligations) | `remaining_performance_obligations_rpo`, `rpo_yoy_pct` | Value in millions (e.g. 353.8) and YoY % (e.g. 55) from the RPO sentence. **Optional:** null for non-SaaS or when not in the release. |
| Full-year non-GAAP net income | `full_year_non_gaap_net_income_millions` | Full-year non-GAAP net income in millions (e.g. 19.7); supports Phase 3/4 "profitability flip" logic. |
| Compute / AI segment growth | `compute_and_ai_revenue_growth_yoy_pct` | YoY % for the segment that includes Compute and Observability. **Optional:** null for non-SaaS or when not in the release. (e.g. "Other revenue … 78% year-over-year"). |

If parsing fails or the URL is missing, those fields are `null`. The prompts (01-phase, 02-metrics) use these fields when present for latest-quarter margin, RPO/visibility, non-GAAP profitability, and AI/segment momentum.

## Updating the URL

After each earnings report, update the contents of `<TICKER>_earnings_url.txt` (or `EARNINGS_URL`) to the new press release URL so the pipeline keeps using the latest quarter.

## Alternative: SEC EDGAR filing URL (`fetch_edgar.sh`)

A simpler, SEC-based source for the **latest 10-Q/10-K document URL** and **quarterly/annual numbers** is available:

- **Script:** `scripts/fetch_edgar.sh`
- **Usage:** `./scripts/fetch_edgar.sh <TICKER>`
- **Output:** When run from `fetch_data.sh`, SEC data is merged into `.cache/data/<TICKER>_data.json` under the key `edgar` and no standalone `*_edgar.json` file is kept. When run standalone, the script writes `.cache/data/<TICKER>_edgar.json` for debugging.

The script uses the public SEC EDGAR API (company_tickers → companyfacts → submissions) and does not rely on IR discovery or earnings press-release parsing. It outputs:

| Field | Description |
|-------|-------------|
| `latest_q_revenue`, `latest_q_net_income`, `latest_fy_revenue` | From XBRL companyfacts with GAAP fallback cascade |
| `latest_10q_url` | Direct URL to the most recent 10-Q or 10-K document on SEC.gov |

You can use `latest_10q_url` as a replacement for the earnings press-release URL when you need a stable, per-ticker filing link (e.g. for parsing or reference). SEC data is updated when 10-Q/10-K is filed (typically 1–4+ weeks after earnings).

## Limitations

- Parser assumes a table layout with rows like "GAAP gross margin" and "Non-GAAP gross margin" and the **first** number = most recent quarter. Unusual layouts may not parse correctly.
- Requires a stable earnings-release URL (e.g. from the company's IR news page). Auto-discovery runs when the file and env are unset; if it fails (e.g. no website or non-standard IR), set the file or EARNINGS_URL manually.
