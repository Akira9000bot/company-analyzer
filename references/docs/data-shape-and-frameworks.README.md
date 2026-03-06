# Data Shape and Framework Impact

This document explains how the unified data file (`*_data.json`) flows into each framework and how the **new/updated data shape** affects analysis. Use it to avoid bugs when adding fields or changing prompts.

## Data flow (high level)

1. **fetch_data.sh** writes a single JSON file: `{ company_profile, financial_metrics, valuation, momentum, sector_context }`.
2. **run-framework.sh** (and thus **analyze-pipeline.sh** / **run-single-step.sh**) loads that file and, per framework, builds a **context** via `get_relevant_context()`: a subset of the JSON (e.g. `profile` + `metrics` + `valuation` + `momentum`).
3. That context is injected into the prompt as **"Raw Data:"** (compact JSON). The model sees the exact keys we put in `financial_metrics` and friends.
4. **09-synthesis** does **not** read the data file directly; it only sees the **text outputs** of the 8 frameworks. So new metrics affect synthesis only indirectly (e.g. 01-phase and 02-metrics mention "margin inflection" or "RPO surge" in their output, and synthesis picks that up).

5. **sector_context** is set from the GICS sector (Yahoo `assetProfile.sector`): sector name, category (TECH, RETAIL, INDUSTRIAL, FINANCE, GENERAL), and **power_metrics** (sector-specific keys). The AI is instructed to favor the sector "king" metric and downweight less relevant ones (e.g. TECH: RPO/AI growth; RETAIL: inventory turnover; INDUSTRIAL: backlog; FINANCE: net interest margin).

## Which frameworks see which data

| Framework   | Context (from run-framework.sh) | Sees new metrics? |
|------------|----------------------------------|--------------------|
| **01-phase** | profile, **metrics**, valuation, momentum | Yes – full `financial_metrics` (including quarterly_trend, margin_inflection, sentiment_inflection, RPO, full_year_non_gaap_net_income_millions, compute_and_ai_revenue_growth_yoy_pct, latest_q_*_gross_margin_pct). |
| **02-metrics** | **metrics**, valuation | Yes – same `financial_metrics`. |
| **07-business** | profile, **metrics**, valuation | Yes – full `financial_metrics`. |
| **03-ai-moat** | momentum, valuation, description | No – no `financial_metrics`; only earnings surprises, valuation, company description. |
| **08-risk** | valuation, momentum, profile | No – no `financial_metrics`; only valuation, momentum, profile. |
| **04, 05, 06** | profile, valuation (default) | No – no `financial_metrics`; they rely on rolling context from prior steps. |

So the **new data shape** directly affects **01-phase**, **02-metrics**, and **07-business**. The others get either no metrics or a fixed subset.

## New / updated fields in `financial_metrics`

All of these are optional (may be `null` or absent if not available):

| Field | Type | Source | Used by |
|-------|------|--------|--------|
| `quarterly_trend` | `{ revenue: [...], gross_margin: [...] }` | Yahoo / AV / imputation | 01-phase, 02-metrics (momentum) |
| `margin_inflection` | boolean | fetch_data (150 bps rule + earnings fallback) | 01-phase, 02-metrics |
| `sentiment_inflection` | boolean | fetch_data (7d estimate revision + beats fallback) | 01-phase, 02-metrics |
| `latest_q_gaap_gross_margin_pct` | string or null | Earnings parser | 01-phase, 02-metrics |
| `latest_q_non_gaap_gross_margin_pct` | string or null | Earnings parser | 01-phase, 02-metrics |
| `remaining_performance_obligations_rpo` | number or null | Earnings parser | 01-phase, 02-metrics. **Optional:** null for non-SaaS or when not reported. |
| `rpo_yoy_pct` | number or null | Earnings parser | 01-phase, 02-metrics. **Optional:** null for non-SaaS or when not reported. |
| `full_year_non_gaap_net_income_millions` | number or null | Earnings parser | 01-phase, 02-metrics |
| `compute_and_ai_revenue_growth_yoy_pct` | number or null | Earnings parser | 01-phase, 02-metrics. **Optional:** null for non-SaaS or when not reported. |
| `quarterly_gross_margin_imputed` | boolean | fetch_data | 01-phase, 02-metrics (for caveats) |

Prompt wording in **01-phase.txt** and **02-metrics.txt** references these by **exact key name** (e.g. `remaining_performance_obligations_rpo`, `rpo_yoy_pct`). Changing a key in `fetch_data.sh` without updating the prompts would break intended behavior.

## Scripts that read the data file directly

- **run-framework.sh**: `get_relevant_context()` uses `jq -c '{...}' "$DATA_FILE"`. It does **not** enumerate keys; it passes whole objects (e.g. `.financial_metrics`). So any new key in `financial_metrics` is automatically included for 01-phase, 02-metrics, 07-business. No script change needed when adding fields.
- **analyze.sh**: Reads only `.valuation.current_price` and `.valuation.target_mean_price` for synthesis. No dependency on the new metrics.
- **analyze-pipeline.sh**: Only checks that `DATA_FILE` exists; does not parse its contents.

So the only places that must stay in sync with the data shape are:

1. **fetch_data.sh** – writes the JSON (keys and types).
2. **01-phase.txt** and **02-metrics.txt** – refer to the same key names and meaning (e.g. margin_inflection, RPO, full_year_non_gaap_net_income_millions).

## Consistency checks (avoiding bugs)

- **Threshold alignment**: The script sets `margin_inflection` when latest margin is **>150 bps** above annual. The prompts now say "meaningfully above annual (>150 bps)" so they match.
- **Earnings-only fields**: RPO, full-year non-GAAP net income, compute/AI growth, and latest-q GAAP/non-GAAP margin come from the earnings parser. If the earnings URL is not set, those fields are `null`; prompts say "when present" so the model simply skips them.
- **Null vs missing**: jq outputs `null` for optional earnings fields when not parsed. The model sees `"remaining_performance_obligations_rpo": null`. Prompts say "when present" / "when … are present"; the model should treat `null` as absent. No extra handling in scripts is required.
- **07-business**: Gets full `financial_metrics` but the prompt does not currently call out RPO or margin_inflection by name. If you want 07-business to use those, add explicit instructions to the 07-business prompt; otherwise the model may or may not use them from the raw JSON.

## Summary

- **New data shape** adds optional fields to `financial_metrics` and is passed through as full objects; **01-phase**, **02-metrics**, and **07-business** see all of them.
- **04, 05, 06** and **03, 08** do not receive `financial_metrics`; they use profile/valuation/momentum or rolling context only.
- **09-synthesis** only sees framework text outputs; it does not read the data file. Confirmation flags (e.g. margin inflection, RPO surge) appear in synthesis only if 01-phase/02-metrics (or others) write them into their output.
- Keep **prompt key names** in 01-phase and 02-metrics in sync with **fetch_data.sh** JSON keys, and keep **margin_inflection** threshold wording in prompts aligned with the **150 bps** logic in the script.
