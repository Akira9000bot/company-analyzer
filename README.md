# Company Analyzer 🛡️

A high-performance, cost-optimized strategic research engine built to analyze public companies using SEC filings and the **Gemini 3 Flash** model. This tool implements a structured, 8-stage sequential pipeline to evaluate business phases, moats, and execution risks for long-term investment conviction. 

---

## 🏗️ Architecture & Pipeline

The system follows a **Sequential Pipeline** model, ensuring that each analysis framework builds upon a consistent logical foundation while preventing API rate-limit bursts. 

1. **Data Layer (`fetch_data.sh`)**: Ingests financial data from SEC EDGAR and localizes it for processing. 


2. **Segmented Ingestion**: `run-framework.sh` dynamically parses SEC filings to send only the relevant segments (e.g., Item 1A for Risk, Item 1 for Business) to the LLM, reducing input costs by up to 90%. 


3. **The 8 Frameworks**:
* 
**01-phase**: Lifecycle diagnosis (Startup, Hyper-Growth, Self-Funding, Operating Leverage, Capital Return, or Decline). 


* 
**02-metrics**: Phase-specific Red/Yellow/Green scorecard using customized thresholds. 


* 
**07-business**: Core unit economics, revenue mix, and recession-resilience audit. 


* 
**03-ai-moat**: Evaluation of AI disruption vs. antifragility using the Four Lenses logic. 


* 
**04-strategic-moat**: Assessment of traditional economic moats and counter-positioning. 


* 
**06-growth**: Analysis of new customer acquisition vs. existing customer expansion strategies. 


* 
**05-sentiment**: Multi-layered analysis across Analyst, Investor, and Media perspectives. 


* 
**08-risk**: Weighted mathematical scoring of execution, disruption, and concentration threats. 





---

## ⚡ Key Features

* 
**Cost Efficiency**: Fully optimized for the **Gemini 3 Flash Paid Tier**, achieving a total analysis cost of **<$0.01 per run**. 


* 
**Dynamic API Client**: Configuration-driven rate limiting (250+ RPM) with automatic model fallback and resilience retries. 


* 
**Zero-Cost Synthesis**: Automatically compiles individual framework reports into a single, cohesive "Final Research Dossier" without additional LLM fees. 


* 
**Persistent Caching**: Uses a localized caching layer in `~/.openclaw/cache` with metadata tracking for tokens, model versions, and latency. 


* 
**Audit Tools**: Includes `ticker-summary.sh` to monitor research spending and framework efficiency. 



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

Run the full sequential pipeline for a specific ticker: 

```bash
./scripts/analyze-pipeline.sh [TICKER] --live

```

### Monitoring

Generate a summary of all research costs and token usage: 

```bash
./scripts/ticker-summary.sh

```

---

## 🛠️ Configuration

* 
**API Configuration**: Managed via `~/.openclaw/agents/main/agent/auth-profiles.json`. 


* 
**Pricing Data**: Update `scripts/lib/prices.json` to adjust for model pricing changes. 


* 
**Global Settings**: Rate limits and default models are pulled dynamically from `~/.openclaw/openclaw.json`.
