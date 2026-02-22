---
name: company-analyzer
description: Investment research and company analysis using 8 specialized frameworks. Use when the user wants to analyze a public company for investment purposes, research competitive positioning, evaluate AI moats, assess business models, or generate investment theses. Trigger on commands like "/analyze", requests to analyze tickers like "AAPL", "analyze company X", or any investment research queries.
---

# CRITICAL: Execution Method

When user triggers "/analyze <TICKER>", you MUST execute the bash script directly:

```bash
cd skills/company-analyzer && ./scripts/analyze.sh <TICKER> --live
```

DO NOT spawn subagents. DO NOT use sessions_spawn. Direct script execution only.

# Company Analyzer

Perform comprehensive investment research on public companies using 8 specialized analysis frameworks.

## Quick Commands

When user types `/analyze <TICKER>`, execute:
```bash
cd skills/company-analyzer && ./scripts/analyze.sh <TICKER> --live
```

For dry run (no cost):
```bash
cd skills/company-analyzer && ./scripts/analyze.sh <TICKER>
```

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

You execute: `cd skills/company-analyzer && ./scripts/analyze.sh AAPL --live`

Runs all 8 frameworks + synthesis. Cost: ~$0.04

## Output

All analyses saved to `outputs/`:
- `TICKER_01-phase.md` through `TICKER_08-risk.md`
- `TICKER_SYNTHESIS.md` - Investment thesis

## Cost Protection

- Daily budget: $0.10 (hard stop)
- Per framework: 500 token max (auto-truncate)
- Circuit breaker: 2 failures max
- Cache retrieval: FREE

## Data Sources

1. Company IR pages (primary)
2. SEC EDGAR filings (fallback)
3. Cached data: `/tmp/company-analyzer-cache/`

## Resources

- **Scripts**: `scripts/analyze.sh` - Main analysis (USE THIS for /analyze triggers)
- **Scripts**: `scripts/fetch_data.sh` - Data acquisition
- **Scripts**: `scripts/synthesize.sh` - Final verdict with screener logic
- **Scripts**: `scripts/cost_tracker.sh` - Cost monitoring
- **References**: `references/prompts/` - 9 framework prompts (01-08 + synthesis)
