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

## Limitations

- Parser assumes a table layout with rows like "GAAP gross margin" and "Non-GAAP gross margin" and the **first** number = most recent quarter. Unusual layouts may not parse correctly.
- Requires a stable earnings-release URL (e.g. from the company's IR news page). Auto-discovery runs when the file and env are unset; if it fails (e.g. no website or non-standard IR), set the file or EARNINGS_URL manually.
