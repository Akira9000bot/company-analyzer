---
name: company-analyzer
description: Investment research and company analysis using 8 specialized frameworks. Use when the user wants to analyze a public company for investment purposes, research competitive positioning, evaluate AI moats, assess business models, or generate investment theses. Trigger on commands like "/analyze", requests to analyze tickers like "AAPL", "analyze company X", or any investment research queries.
---

# Company Analyzer

Perform comprehensive investment research on public companies using 8 specialized analysis frameworks.

## Quick Commands

```bash
# Full analysis (all 8 frameworks + synthesis)
./analyze <TICKER>

# Single framework (or retrieve from cache)
./analyze <TICKER> <NUMBER>
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

### Full Analysis
```bash
./analyze AAPL
```
Runs all 8 frameworks + synthesis. Cost: ~$0.03

### Single Framework
```bash
./analyze AAPL 3    # AI Moat only
```
Runs one framework (or retrieves from cache). Cost: ~$0.003 or FREE

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

- **Scripts**: `scripts/analyze` - Main command interface
- **Scripts**: `scripts/analyze.sh` - Orchestrator with protections
- **Scripts**: `scripts/fetch_data.sh` - Data acquisition
- **Scripts**: `scripts/synthesize.sh` - Thesis preparation
- **Scripts**: `scripts/cost_tracker.sh` - Cost monitoring
- **References**: `references/prompts/` - 8 framework prompts
