# Company Analyzer 🛡️

A high-performance, cost-optimized strategic research engine that analyzes public companies using SEC filings and your **OpenClaw-configured LLM**. It implements a structured, 8-stage pipeline to evaluate business phases, moats, and execution risks for long-term investment conviction.

---

## 📋 Two pipeline flows

You can run the 8 frameworks in two ways. Both produce `assets/outputs/<TICKER>_01-phase.md` through `<TICKER>_08-risk.md`; they differ in how `FINAL_REPORT.md` is built.

| Flow | Script | `FINAL_REPORT.md` | Use when |
|------|--------|-------------------|----------|
| **Synthesis** | `analyze.sh` | One LLM synthesis step: VERDICT (BUY/HOLD/SELL), VALUATION ANCHORS, WEIGHTED SCORECARD, NARRATIVE FLIP RADAR, STRUCTURAL FLAGS, KEY RISKS, INVESTMENT THESIS, ADJUSTMENTS. | You want a single verdict and actionable summary (e.g. `/analyze` from Telegram or CLI). |
| **Dossier** | `analyze-pipeline.sh` | Concatenation of all 8 framework outputs into one file (Strategic Research Dossier with ## PHASE, ## METRICS, ## RISK, etc.). No extra LLM call. | You want the full text of every framework in one place for audit or deep dive. |

**Examples**

```bash
# From the skill directory (e.g. ~/.openclaw/workspace/skills/company-analyzer)

# Synthesis report (default for /analyze) — verdict + summary
./scripts/analyze.sh AAPL --live
# → assets/outputs/AAPL_FINAL_REPORT.md = VERDICT, VALUATION ANCHORS, WEIGHTED SCORECARD, etc.

# Dossier — all framework sections in one file
./scripts/analyze-pipeline.sh TXN --live
# → assets/outputs/TXN_FINAL_REPORT.md = Strategic Research Dossier (01-phase through 08-risk)

# Single framework only (no FINAL_REPORT)
./scripts/run-single-step.sh KVYO 02-metrics
# → assets/outputs/KVYO_02-metrics.md only (use ticker KVYO for Klaviyo)
```

---

## 🏗️ Architecture & Pipeline

The system runs 8 frameworks; the **synthesis** flow (analyze.sh) runs all 8 frameworks sequentially, then one synthesis LLM call (sequential avoids provider rate limits and context overflow when run via bot). The **dossier** flow (analyze-pipeline.sh) runs all 8 sequentially and concatenates their outputs.

1. **Data Layer (`fetch_data.sh`)**: Ingests financial data from **Yahoo Finance** (quote + quoteSummary), **SEC EDGAR** (company facts for revenue, net income, FCF, and share count trend), and **Alpha Vantage** (fallback for FCF, quarterly revenue YoY, and shares when Yahoo/SEC leave them N/A). Configure the Alpha Vantage profile in OpenClaw auth profiles to enable the fallback. 


2. **Segmented Ingestion**: `run-framework.sh` injects only the relevant context per framework from the enriched data file (e.g. profile + metrics for Phase, valuation + momentum for Risk), keeping prompts focused and costs down. 


3. **The 8 Frameworks**:
* **01-phase**: Lifecycle diagnosis (Startup, Hyper-Growth, Self-Funding, Operating Leverage, Capital Return, or Decline). 


* **02-metrics**: Phase-specific Red/Yellow/Green scorecard using customized thresholds. 


* **07-business**: Core unit economics, revenue mix, and recession-resilience audit. 


* **03-ai-moat**: Evaluation of AI disruption vs. antifragility using the Four Lenses logic. 


* **04-strategic-moat**: Assessment of traditional economic moats and counter-positioning. 


* **06-growth**: Analysis of new customer acquisition vs. existing customer expansion strategies. 


* **05-sentiment**: Multi-layered analysis across Analyst, Investor, and Media perspectives. 


* **08-risk**: Weighted mathematical scoring of execution, disruption, and concentration threats. 





---

## ⚡ Key Features

* **Cost Efficiency**: Cost depends on your configured LLM and pricing; cost tracking uses `scripts/lib/prices.json` (keyed by model id). 


* **Dynamic API Client**: Configuration-driven rate limiting (from OpenClaw config; default 250 RPM) and retries on transient API errors (e.g. 503). 


* **Two report modes**: **Synthesis** (analyze.sh) — one LLM synthesis step for VERDICT and summary. **Dossier** (analyze-pipeline.sh) — concatenates all 8 framework outputs into one file with no extra LLM call. 


* **Persistent Caching**: Uses a caching layer under the skill (`.cache/llm-responses/`); falls back to `~/.openclaw/cache/company-analyzer/llm-responses/` if the skill directory is read-only. Metadata tracks tokens and model. 


* **Audit Tools**: Includes `ticker-summary.sh` to monitor research spending and framework efficiency. 



---

## 🚀 Getting Started

### Installation

Ensure you have `jq` and `bc` installed on your system to handle JSON parsing and cost calculations. 

```bash
# Clone the skill into your OpenClaw workspace
git clone [repo-url] ~/.openclaw/workspace/skills/company-analyzer

# Ensure scripts are executable
chmod +x ~/.openclaw/workspace/skills/company-analyzer/scripts/*.sh

```

### Usage

From the skill directory (e.g. `cd ~/.openclaw/workspace/skills/company-analyzer`):

**Synthesis report** (verdict + summary; use for `/analyze` or when you want BUY/HOLD/SELL and anchors):

```bash
./scripts/analyze.sh AAPL --live
```

**Dossier report** (all 8 framework sections in one file; no synthesis LLM):

```bash
./scripts/analyze-pipeline.sh TXN --live
```

**Single framework only** (e.g. 01-phase or 02-metrics; no FINAL_REPORT):

```bash
./scripts/run-single-step.sh KVYO 02-metrics
```

**Dry run** (no API calls):

```bash
./scripts/analyze.sh TEAM
```

### Monitoring

Cost and token summary:

```bash
cd skills/company-analyzer && ./scripts/ticker-summary.sh
```

Trace logs (per ticker, per day) are in `assets/traces/<TICKER>_<YYYY-MM-DD>.trace` for debugging failed steps.

---

## 🛠️ Configuration

* **API configuration**: Model and API keys are read from OpenClaw config (no hardcoded provider or keys). Set your LLM and auth in OpenClaw; the skill uses the primary model and the matching auth profile (`{provider}:default`). 


* **Pricing**: Add your model's pricing to `scripts/lib/prices.json` (key = model id from OpenClaw config) for cost tracking. See `scripts/lib/prices.README.md`.

* **LLM provider**: The built-in API client uses a request/response format compatible with Google Generative AI–style APIs. The model and key are read from OpenClaw config; other providers with a compatible API (same URL shape and JSON format) can be used by configuring that provider in OpenClaw. 


* **Rate limits**: Read from OpenClaw config; default 250 RPM. Output token cap is a single high default (8192) so responses are not truncated.
