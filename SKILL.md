---
name: company-analyzer
description: Investment research and company analysis using 8 specialized frameworks. Use when the user wants to analyze a public company for investment purposes, research competitive positioning, evaluate AI moats, assess business models, or generate investment theses. Trigger on commands like "/analyze", requests to analyze tickers like "AAPL", "analyze company X", or any investment research queries.
---

# CRITICAL: Execution Method

When user triggers "/analyze <TICKER>", you MUST execute the bash script directly:

```bash
cd skills/company-analyzer && ./scripts/analyze-parallel.sh <TICKER> --live
```

DO NOT spawn subagents. DO NOT use sessions_spawn. Direct script execution only.

# Company Analyzer

Perform comprehensive investment research on public companies using 8 specialized analysis frameworks with **parallel execution**, **response caching**, and **cost controls**.

**Note:** Synthesis phase removed. Analysis returns 8 framework outputs without consolidated verdict.

## Quick Commands

When user types `/analyze <TICKER>`, execute:
```bash
cd skills/company-analyzer && ./scripts/analyze-parallel.sh <TICKER> --live
```

For dry run (no cost):
```bash
cd skills/company-analyzer && ./scripts/analyze-parallel.sh <TICKER>
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

You execute: `cd skills/company-analyzer && ./scripts/analyze-parallel.sh AAPL --live`

Runs all 8 frameworks in parallel. Cost: ~$0.03 (or $0 if cached).

### Data Fetching
Before analysis, fetch company data:
```bash
cd skills/company-analyzer && ./scripts/fetch_data.sh AAPL
```

This pulls:
- Financial metrics from SEC EDGAR
- Price data from Alpha Vantage (if API key configured)

### Run Single Framework
```bash
cd skills/company-analyzer && ./scripts/run-framework.sh AAPL 03-ai-moat --live
```

## Architecture

### Scripts
- **`analyze-parallel.sh`** - Main orchestrator (parallel execution)
- **`run-framework.sh`** - Single framework runner with caching
- **`fetch_data.sh`** - Data acquisition (SEC + Alpha Vantage)
- **`lib/cache.sh`** - Response caching utilities
- **`lib/cost-tracker.sh`** - Budget management
- **`lib/api-client.sh`** - Moonshot API with retry logic

### Caching
- Location: `/.openclaw/cache/company-analyzer/responses/`
- TTL: 7 days
- Key: `TICKER_FWID_PROMPT_HASH`
- Cached responses show: `💰 framework: $0.0000 (cached)`

### Cost Tracking (No enforced limits)
- Costs are logged for visibility
- No spending limit enforced
- Run as many analyses as needed

## Configuration

### Alpha Vantage (Price Data)
Add to `~/.openclaw/agents/main/agent/auth-profiles.json`:
```json
{
  "profiles": {
    "alpha-vantage:default": {
      "key": "YOUR_API_KEY"
    }
  }
}
```

Free tier: 25 API calls/day

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
| **Parallel (token-limited)** | ~4s | **~$0.018** |
| Cached | ~1s | $0.00 |

**Token Limits Applied:**
- API-level `max_tokens` enforced per framework
- Prompt-level strict output constraints
- Average output reduced from ~1,600 to ~700 tokens
- **60% cost reduction** vs unlimited output

## Troubleshooting

**"Alpha Vantage rate limit":
- Free tier = 25 calls/day
- Price data falls back to N/A, analysis continues with SEC data only

**Framework failures:**
- Individual frameworks can fail without stopping entire analysis
- Check `assets/outputs/` for partial results
