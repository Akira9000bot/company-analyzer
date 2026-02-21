# Company Analyzer v6.5 - Live End-to-End

**Complete investment research with AI-generated analysis and thesis.**

---

## 🚀 Quick Start (New Behavior)

### Full Live Analysis (Default)
```bash
./analyze <TICKER>
```
**Example:** `./analyze AAPL`

Runs **LIVE API analysis**:
1. Analyzes all 8 frameworks via AI (~$0.024)
2. Generates investment thesis (~$0.01)
3. **Total cost: ~$0.034**
4. Returns complete verdict: BUY/HOLD/SELL

### Single Framework
```bash
./analyze <TICKER> <NUMBER>
```
**Example:** `./analyze AAPL 3` (AI Moat only)

Cost: ~$0.003 per framework

---

## 📊 Frameworks (1-8)

| # | Name | Focus |
|---|------|-------|
| 1 | Phase Classification | Startup/Growth/Maturity/Decline |
| 2 | Key Metrics Scorecard | Financial health dashboard |
| 3 | AI Moat Viability | AI-native competitive advantage |
| 4 | Strategic Moat | Competitive durability |
| 5 | Price & Sentiment | Valuation + market sentiment |
| 6 | Growth Drivers | New vs existing customer mix |
| 7 | Business Model | Unit economics & delivery |
| 8 | Risk Analysis | Key threats & scenarios |

---

## 💰 Cost Structure

| Command | What Happens | Cost |
|---------|-------------|------|
| `./analyze TICKER` | 8 frameworks + thesis | **~$0.034** |
| `./analyze TICKER 3` | Single framework | **~$0.003** |
| `./analyze TICKER live` | Force live mode | **~$0.034** |

**Daily Budget:** $0.10 (auto-stops if exceeded)

---

## 📁 Output Files

All saved to `assets/outputs/`:
- `TICKER_01-phase.md` through `TICKER_08-risk.md` — AI-generated analysis
- `TICKER_SYNTHESIS_live.md` — Investment thesis with verdict

---

## 🎯 Example Output

```
$ ./analyze MU

🚀 Running FULL LIVE ANALYSIS for MU
   • 8 frameworks via API (~$0.024)
   • Investment thesis (~$0.01)
   • Total: ~$0.034

🔍 [01-phase] Phase Classification
  💰 $0.0033
  ✅ Complete

🔍 [02-metrics] Key Metrics Scorecard
  💰 $0.0033
  ✅ Complete

... (all 8 frameworks)

🧠 Generating Investment Thesis...
  💰 $0.012
  📊 Verdict: BUY

======================================
✅ LIVE ANALYSIS COMPLETE
======================================

📁 Output files:
   • MU_01-phase.md
   • MU_02-metrics.md
   ...
   • MU_SYNTHESIS_live.md

💰 Total cost: $0.034

📊 THESIS PREVIEW:
Verdict: BUY
Confidence: High
Executive Summary: Micron's HBM3E positioning in AI memory...
```

---

## 🛡️ Protections

- **$0.10 daily budget** — hard stop
- **500 token limit** per framework
- **Circuit breaker** — stops after 2 failures
- **Cost tracking** — logs every API call

---

## 📍 Location

```
skills/company-analyzer/
├── scripts/analyze          ← main command
├── scripts/analyze-live.sh  ← live engine
├── references/prompts/      ← 8 framework prompts
└── assets/outputs/          ← results
```

---

## 🔗 Repository

https://github.com/Akira9000bot/company-analyzer

---

*Built with OpenClaw + Kimi K2.5*
