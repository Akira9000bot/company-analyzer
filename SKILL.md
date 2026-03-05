---
name: company-analyzer
description: Investment research and company analysis using 8 specialized frameworks. Use when the user wants to analyze a public company for investment purposes, research competitive positioning, evaluate AI moats, assess business models, or generate investment theses. Trigger on commands like "/analyze", requests to analyze tickers like "AAPL", "analyze company X", or any investment research queries.
---

# CRITICAL: Execution Method

**Full pipeline** (all 8 frameworks + synthesis): when user asks to "analyze &lt;TICKER&gt;" or "run full analysis" (no "only" one step):
```bash
cd skills/company-analyzer && ./scripts/analyze-pipeline.sh <TICKER> --live
```

**Single step only** (e.g. "only 02-metrics" or "only produce 01-phase"): do NOT use --live. Run:
```bash
cd skills/company-analyzer && ./scripts/run-single-step.sh <TICKER> <FW_ID>
```
Example: only 02-metrics for KVYO → `./scripts/run-single-step.sh KVYO 02-metrics`. Output appears at `assets/outputs/<TICKER>_<FW_ID>.md` after the script completes. Do not read that file before running the script.

DO NOT spawn subagents. DO NOT use sessions_spawn. Direct script execution only.

# Company Analyzer

Perform comprehensive investment research on public companies using 8 specialized analysis frameworks with **response caching** and **cost controls**.

## Quick Commands

When user types `/analyze <TICKER>`, execute:
```bash
cd skills/company-analyzer && ./scripts/analyze.sh <TICKER> --live
```

For dry run (no cost):
```bash
cd skills/company-analyzer && ./scripts/analyze.sh <TICKER>
```

## Features

| Feature | Benefit |
|---------|---------|
| **Parallel Execution** | 8 frameworks run simultaneously (~4-6s vs ~20s sequential) |
| **Response Caching** | Re-analyzing same ticker uses cache = ~50-80% cost savings |
| **Cost Tracking** | Logs spending for visibility (no enforced limits) |
| **Alpha Vantage** | Price data (P/E, market cap) when API key configured |
| **Retry Logic** | 3 retries with exponential backoff on API failures |

## Frameworks

| # | Name | Focus |
|---|------|-------|
| 1 | Phase Classification | Startup/Growth/Maturity/Decline |
| 2 | Key Metrics Scorecard | Financial health dashboard |
| 3 | AI Moat Viability | AI-native competitive advantage |
| 4 | Strategic Moat | Competitive durability analysis |
| 5 | Price & Sentiment | Valuation + market sentiment |
| 6 | Growth Drivers | New vs existing customer mix |
| 7 | Business Model | Unit economics & delivery |
| 8 | Risk Analysis | Key threats & scenarios |

## Usage

### Full Analysis (via Telegram/command)
User types: `/analyze AAPL`

You execute: `cd skills/company-analyzer && ./scripts/analyze-pipeline.sh AAPL --live`

Runs all 8 frameworks in parallel. Cost: ~$0.03 (or $0 if cached).

### Data Fetching
Before analysis, fetch company data:
```bash
cd skills/company-analyzer && ./scripts/fetch_data.sh AAPL
```

This pulls:
- Financial metrics from SEC EDGAR
- Price data from Alpha Vantage (if API key configured)

### Run only one framework (no pipeline, no synthesis)
When the user asks for "only 02-metrics" or "only produce 01-phase", run a single step. Do **not** use `--live` here (that flag is only for the full pipeline).

```bash
cd skills/company-analyzer && ./scripts/run-single-step.sh <TICKER> <FW_ID>
```

Examples:
- Only 02-metrics: `./scripts/run-single-step.sh KVYO 02-metrics`
- Only 01-phase: `./scripts/run-single-step.sh KVYO 01-phase`

Valid `FW_ID` values: `01-phase`, `02-metrics`, `03-ai-moat`, `04-strategic-moat`, `05-sentiment`, `06-growth`, `07-business`, `08-risk`.

Output is written to `assets/outputs/<TICKER>_<FW_ID>.md` (e.g. `KVYO_02-metrics.md`). Wait for the script to finish before reading that file. Use ticker **KVYO** for Klaviyo (not KYVO).

## Architecture

### Scripts
- **`analyze-parallel.sh`** - Main orchestrator (parallel execution)
- **`run-framework.sh`** - Single framework runner with caching
- **`fetch_data.sh`** - Data acquisition (SEC + Alpha Vantage)
- **`lib/cache.sh`** - Response caching utilities
- **`lib/cost-tracker.sh`** - Budget management
- **`lib/api-client.sh`** - Moonshot API with retry logic

### Caching
- Location: `skills/company-analyzer/.cache/responses/` (skill dir); falls back to `~/.openclaw/cache/company-analyzer/responses/` if skill dir is read-only
- TTL: 7 days
- Key: `TICKER_FWID_PROMPT_HASH`
- Cached responses show: `💰 framework: $0.0000 (cached)`

### Cost Tracking (No enforced limits)
- Costs are logged for visibility
- No spending limit enforced
- Run as many analyses as needed

## Configuration

### Alpha Vantage (fallback for FCF, revenue_q_yoy)
When Yahoo/SEC leave `fcf` or `revenue_q_yoy` as N/A, fetch_data.sh uses Alpha Vantage if a key is configured. Add to `~/.openclaw/agents/main/agent/auth-profiles.json`:
```json
{
  "profiles": {
    "alpha-vantage:default": {
      "key": "YOUR_API_KEY"
    }
  }
}
```
Uses: INCOME_STATEMENT (quarterly revenue for YoY), CASH_FLOW (FCF). Free tier: 25 API calls/day; script uses up to 2 calls per ticker with 2s delay between.

### Moonshot API
Already configured via OpenClaw auth profiles.

## Output

All analyses saved to `assets/outputs/`:
- `TICKER_01-phase.md` through `TICKER_08-risk.md`

*(Synthesis phase removed for cost efficiency)*

## Performance

| Mode | Time | Cost |
|------|------|------|
| Sequential (old) | ~20s | $0.04 |
| Parallel (8 frameworks, unlimited) | ~4s | ~$0.045 |
| **Parallel (Gemini 2.0 Flash)** | ~5s | **~$0.003** |
| Cached | ~1s | $0.00 |

**Gemini 2.0 Flash Benefits:**
- No reasoning overhead - all tokens go to content
- 10x cheaper than Kimi: $0.075/M input, $0.30/M output
- Built-in rate limiting (15 RPM free tier)
- Estimated cost per analysis: ~$0.003 (vs ~$0.035 with Kimi)

## Troubleshooting

**"Alpha Vantage rate limit":**
- Free tier = 25 calls/day
- Price data falls back to N/A, analysis continues with SEC data only

**"API key has run out of credits" / "insufficient balance" / 1M TPM spike:**
- Caused by **billing or TPM (tokens per minute) limit** on the Gemini API key. The pipeline now uses a **45s cooldown** between steps to reduce TPM spikes.
- **Fix:** Top up the key in Google AI Studio, or switch to another API key in `auth-profiles.json`. Avoid running many analyses back-to-back; space runs by at least a few minutes.

**"Analysis failed (code 1)" / Heartbeat alert after 01-phase or 02-metrics:**
- Often **HTTP 503** (Service Unavailable) or **billing/quota (402, 403)**. The pipeline continues after a failed step and still builds a partial report.
- **Fix:** For 503, re-run later. For billing, top up or switch key (see above). Run from the skill directory: `cd skills/company-analyzer && ./scripts/analyze-pipeline.sh <TICKER> --live`.

**Framework failures:**
- Failed steps are listed at the end; partial outputs remain in `assets/outputs/`. Check `assets/traces/<TICKER>_<date>.trace` for which step failed and why.
