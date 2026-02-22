# Company Analyzer Skill

8-framework investment analysis with live API execution and cost tracking.

## Quick Start

```bash
# Dry run (no cost)
./scripts/analyze.sh AAPL

# Live analysis (~$0.03-0.05)
./scripts/analyze.sh AAPL --live

# With Telegram delivery
./scripts/analyze.sh AAPL --live --telegram 123456789
```

## Requirements

- `jq` (JSON parsing)
- `bc` (cost calculations)
- `MOONSHOT_API_KEY` environment variable

```bash
export MOONSHOT_API_KEY="your-key-here"
```

## How It Works

### 1. Prepare Data
Create JSON file with company data:
```bash
/tmp/company-analyzer-cache/AAPL_data.json
```

Or use the fetch helper:
```bash
./scripts/fetch_data.sh AAPL
```

### 2. Run Analysis
The `analyze.sh` script:
1. Creates a shared Moonshot cache (10-min TTL)
2. Runs 8 frameworks in parallel via API
3. Logs cost per framework
4. Runs synthesis with binary screener logic
5. Optionally delivers to Telegram (chunked)

### 3. View Results
- Framework outputs: `assets/outputs/AAPL_01-phase.md` through `AAPL_08-risk.md`
- Synthesis: `assets/outputs/AAPL_synthesis.md`
- Cost log: `/tmp/company-analyzer-costs.log`

## The 8 Frameworks

| # | Framework | Output |
|---|-----------|--------|
| 01 | Phase Classification | Business lifecycle stage |
| 02 | Metrics Scorecard | 🟢🟡🔴 financial health |
| 03 | AI Moat Viability | Fragile/Robust/Antifragile |
| 04 | Strategic Moat | None/Narrow/Wide assessment |
| 05 | Price & Sentiment | Valuation + market sentiment |
| 06 | Growth Drivers | Revenue breakdown |
| 07 | Business Model | Unit economics |
| 08 | Risk Analysis | Top 3 ranked risks |

## Synthesis (The 9th Framework)

The synthesis step applies **strategic screener logic**:

### Binary Narrative Flip Detection
Scans for 180° thesis reversals:
- Growth → Value trap
- Hardware → Failed services pivot
- Wide moat → Erosion

If detected: conviction penalized by 1 level

### Seat-Based SaaS Penalty
If >50% revenue from "seats" or "users":
- FLAG: "Seat-based model at risk from AI"
- Apply -20% to fair value
- Justify: AI agents replace human seats

### Output
```
🎯 BINARY VERDICT: [BUY / HOLD / SELL]
Conviction: [High / Medium / Low]

🔄 Narrative Flip Radar: [🟢🟡🔴]
⚠️ Structural Flags: [Seat-based SaaS: YES/NO]
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `analyze.sh` | **Main script** — 8 frameworks + synthesis |
| `synthesize.sh` | Final verdict with screener logic |
| `fetch_data.sh` | Helper to fetch company data |
| `retrieve.sh` | Retrieve saved outputs |
| `budget_guard.sh` | Enforce daily spending limit |
| `cost_tracker.sh` | Log token usage |
| `validate_output.sh` | Quality checks |

## Cost Structure

| Component | Cost |
|-----------|------|
| 8 frameworks | ~$0.02-0.04 |
| Synthesis | ~$0.01-0.02 |
| **Total** | **~$0.03-0.06** |

Daily budget enforcement: **$0.10** (configurable in script)

## Architecture Updates (v7.0)

1. **Shared Cache**: Single CACHE_ID for all frameworks + synthesis
2. **Parallel Execution**: All 8 frameworks run simultaneously
3. **Cost Logging**: Per-framework token tracking
4. **Telegram Chunking**: 4K character safe delivery
5. **Synthesis Screener**: Narrative flip + seat-based penalty

## Troubleshooting

**"MOONSHOT_API_KEY not set"**
```bash
export MOONSHOT_API_KEY="sk-..."
```

**"jq not found"**
```bash
sudo apt-get install jq  # Ubuntu/Debian
brew install jq          # macOS
```

**"Daily budget exceeded"**
- Check: `cat /tmp/company-analyzer-costs.log`
- Reset: `rm /tmp/company-analyzer-costs.log`
- Or modify limit in `analyze.sh`

## Files

```
skills/company-analyzer/
├── SKILL.md                    # Skill definition
├── README.txt                  # This file
├── scripts/
│   ├── analyze.sh              # Main analysis script ⭐
│   ├── synthesize.sh           # Synthesis with screener
│   └── ...                     # Helper scripts
├── references/prompts/
│   ├── 01-phase.txt            # Framework prompts
│   ├── ...
│   └── 09-synthesis.txt        # Synthesis screener prompt
└── assets/outputs/             # Analysis results (gitignored)
```

## GitHub

https://github.com/Akira9000bot/company-analyzer
