---
name: company-analyzer
description: Investment research and company analysis using 8 specialized frameworks. Use when the user wants to analyze a public company for investment purposes, research competitive positioning, evaluate AI moats, assess business models, or generate investment theses. Trigger on commands like "/analyze", requests to analyze tickers like "AAPL", "analyze company X", or any investment research queries.
---

# MANDATORY: /analyze uses analyze.sh only

When the user sends **/analyze &lt;TICKER&gt;** (e.g. /analyze ADBE), you **MUST** run **analyze.sh**—never analyze-pipeline.sh. analyze.sh produces the synthesis report (VERDICT, VALUATION ANCHORS, WEIGHTED SCORECARD). analyze-pipeline.sh produces a dossier (concatenated framework sections) and is only for when the user explicitly asks for the "dossier" or "full framework output in one file."

**Exact command for /analyze:**
```bash
cd skills/company-analyzer && ./scripts/analyze.sh <TICKER> --live
```
Example: `/analyze ADBE` → `cd skills/company-analyzer && ./scripts/analyze.sh ADBE --live`

# CRITICAL: Execution Method

**Full pipeline** (all 8 frameworks + synthesis): when user asks to "analyze &lt;TICKER&gt;" or "run full analysis" (no "only" one step), use **analyze.sh** so the final report is the synthesis output (VERDICT, VALUATION ANCHORS, WEIGHTED SCORECARD, etc.). Do NOT use analyze-pipeline.sh for /analyze—it produces a different (dossier) format.
```bash
cd skills/company-analyzer && ./scripts/analyze.sh <TICKER> --live
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
| **Alpha Vantage** | Price data (P/E, market cap) when configured in OpenClaw auth profiles |
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

You execute: `cd skills/company-analyzer && ./scripts/analyze.sh AAPL --live`

Runs 8 frameworks sequentially then synthesis (sequential avoids provider rate limits and context overflow when run via bot/agent). FINAL_REPORT.md = synthesis output (VERDICT, VALUATION ANCHORS, etc.). Cost: ~$0.03 (or $0 if cached).

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

## Two pipeline flows

| Flow | Script | Output `FINAL_REPORT.md` | When to use |
|------|--------|--------------------------|--------------|
| **Synthesis** | `analyze.sh` | LLM synthesis: VERDICT, VALUATION ANCHORS, WEIGHTED SCORECARD, NARRATIVE FLIP RADAR, STRUCTURAL FLAGS, KEY RISKS, INVESTMENT THESIS, ADJUSTMENTS. | Default for `/analyze <TICKER>`, Telegram, or when you want a single verdict and actionable summary. |
| **Dossier** | `analyze-pipeline.sh` | Concatenated framework outputs: header + framework weights, then each of the 8 framework `.md` sections (01-phase through 08-risk) in one file. No synthesis LLM call. | When you want all framework text in one place for audit, deep dive, or sharing. |

**Examples**

- Synthesis (verdict + summary):  
  `cd skills/company-analyzer && ./scripts/analyze.sh AAPL --live`  
  → `assets/outputs/AAPL_FINAL_REPORT.md` = BUY/HOLD/SELL, anchors, scorecard, thesis.

- Dossier (full framework text):  
  `cd skills/company-analyzer && ./scripts/analyze-pipeline.sh AAPL --live`  
  → `assets/outputs/AAPL_FINAL_REPORT.md` = Strategic Research Dossier with ## PHASE, ## METRICS, ## RISK, etc.  
  Use when the user asks for the "dossier", "full framework output", "all frameworks in one file", or "concatenated report".

- Single framework (no report):  
  `cd skills/company-analyzer && ./scripts/run-single-step.sh KVYO 02-metrics`  
  → `assets/outputs/KVYO_02-metrics.md` only.

## Architecture

### Scripts
- **`analyze.sh`** - Synthesis flow: runs 8 frameworks sequentially then **09-synthesis** LLM; writes synthesis output to `FINAL_REPORT.md`. Use for `/analyze <TICKER>`.
- **`analyze-pipeline.sh`** - Dossier flow: runs 8 frameworks sequentially and writes a **concatenated dossier** to `FINAL_REPORT.md`. Use when you need the full framework text in one file.
- **`run-framework.sh`** - Single framework runner with caching; validates output for required end-markers (does not cache truncated responses; re-run step to get a fresh response)
- **`fetch_data.sh`** - Data acquisition (SEC + Alpha Vantage)
- **`lib/cache.sh`** - Response caching utilities
- **`lib/cost-tracker.sh`** - Budget management
- **`lib/api-client.sh`** - LLM API client (OpenClaw-configured model and auth); retry logic for transient errors

### Truncation handling
- After each framework response, the script checks for a required end-marker (e.g. 01-phase: `Avoid:`, 02-metrics: `SUMMARY:`). If missing, the output is still saved but not cached, and the step exits with code 1.
- **Diagnostics:** On truncation, the trace logs `finishReason`, output token count, and limit; stderr explains the cause:
  - **MAX_TOKENS** → Response hit the token limit; increase that framework’s limit or shorten the prompt.
  - **STOP** → Model stopped early; the prompt may need a stronger “must complete through [end-marker]” instruction (see 01-phase for an example).
- Re-run that step (or the full pipeline) to get a fresh response.

### Caching
- Location: `skills/company-analyzer/.cache/llm-responses/` (skill dir); falls back to `~/.openclaw/cache/company-analyzer/llm-responses/` if skill dir is read-only
- TTL: 7 days
- Key: `TICKER_FWID_PROMPT_HASH`
- Cached responses show: `💰 framework: $0.0000 (cached)`

### Cost Tracking (No enforced limits)
- Costs are logged for visibility
- No spending limit enforced
- Run as many analyses as needed

## Configuration

### Alpha Vantage (fallback for FCF, revenue_q_yoy)
When Yahoo/SEC leave `fcf` or `revenue_q_yoy` as N/A, fetch_data.sh uses Alpha Vantage if configured. Add the Alpha Vantage profile to OpenClaw auth profiles (e.g. `alpha-vantage:default` with your key).
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

### LLM / API
Model and API key are read from OpenClaw config (primary model and `{provider}:default` auth profile). No hardcoded provider or keys. Add your model's pricing to `scripts/lib/prices.json` for cost tracking.

## Output

All analyses saved to `assets/outputs/`:
- `TICKER_01-phase.md` through `TICKER_08-risk.md` (always)
- `TICKER_FINAL_REPORT.md` — **Synthesis flow** (analyze.sh): verdict, anchors, scorecard, thesis. **Dossier flow** (analyze-pipeline.sh): concatenated framework sections in one file.

## Performance

| Mode | Time | Cost |
|------|------|------|
| Sequential (old) | ~20s | $0.04 |
| Parallel (8 frameworks, unlimited) | ~4s | ~$0.045 |
| **Configured LLM** | ~5–20s | Depends on model and pricing |
| Cached | ~1s | $0.00 |

**Cost tracking:**
- No reasoning overhead - all tokens go to content
- Built-in rate limiting from OpenClaw config. Cost per analysis depends on your LLM; add rates to `scripts/lib/prices.json`.

## Troubleshooting

**"Alpha Vantage rate limit":**
- Free tier = 25 calls/day
- Price data falls back to N/A, analysis continues with SEC data only

**"API key has run out of credits" / "insufficient balance" / rate limit:**
- Caused by billing or rate limits on your configured LLM provider. The pipeline uses a **45s cooldown** between steps to reduce spikes.
- **Fix:** Top up or switch the API key in OpenClaw auth profiles for your provider. Avoid running many analyses back-to-back; space runs by at least a few minutes.

**"Analysis failed (code 1)" / Heartbeat alert after 01-phase or 02-metrics:**
- Often **HTTP 503** (Service Unavailable) or **billing/quota (402, 403)**. The pipeline continues after a failed step and still builds a partial report.
- **Fix:** For 503, re-run later. For billing, top up or switch key (see above). Run from the skill directory: `cd skills/company-analyzer && ./scripts/analyze.sh <TICKER> --live`.

**Framework failures:**
- Failed steps are listed at the end; partial outputs remain in `assets/outputs/`. Check `assets/traces/<TICKER>_<date>.trace` for which step failed and why.

**"Pipeline timeout" / "Frameworks X and Y did not complete":**
- The pipeline runs all 8 frameworks **sequentially** to avoid provider rate limits (e.g. Google cooldown) and context overflow when run via Telegram/bot. Each framework step has a **120s timeout** (override with `FW_TIMEOUT_SEC=180` if your API is slow). If a step times out or fails, the rest still run and synthesis uses whatever completed. To give the run more time, increase the timeout: `FW_TIMEOUT_SEC=180 ./scripts/analyze.sh VSAT --live`.
