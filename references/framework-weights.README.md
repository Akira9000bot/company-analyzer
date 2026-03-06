# Framework Weights

`framework-weights.json` defines **how much each of the 8 frameworks influences the final verdict** when evidence is combined or when frameworks disagree. Weights are a single source of truth: the synthesis prompt (09-synthesis.txt) instructs the model to use the injected numeric weights rather than any hardcoded tiers.

## What the weights do

- **Relative influence:** Higher weight = more influence when the model combines evidence and resolves conflicts. A framework at 20% has more say than one at 6.25% when they point in different directions (e.g. Phase says “growth” but Risk says “high”).
- **Conflict resolution:** When frameworks conflict, the model is told to defer to higher-weight frameworks. So raising a framework’s weight makes it more likely to override others; lowering it makes it more “supporting” (confirm or qualify, not override).
- **Sum = 1.0:** All weights must sum to 1.0. They are treated as a normalized distribution (e.g. 0.20 = 20%).

## Where the weights are used

| Use | Script / behavior |
|-----|--------------------|
| **Synthesis verdict** | `analyze.sh` injects a line like `NUMERIC FRAMEWORK WEIGHTS (total 100% of verdict influence; ...): 01-phase=20%, 02-metrics=20%, ...` into the 09-synthesis prompt. The LLM uses these percentages to weight each framework when forming BUY/HOLD/SELL. |
| **Final report order and labels** | `analyze-pipeline.sh` orders report sections by weight (highest first) and adds the weight to each section header (e.g. `## PHASE (20%)`). The report header also lists all weights. |

Changing `framework-weights.json` is enough to change both synthesis behavior and report ordering; no edits to prompt text are required.

## Default weighting (current JSON)

- **01-phase, 02-metrics, 08-risk** — 20% each (60% total). Lifecycle phase, phase-specific metrics, and risk are treated as the main anchors; weak phase/metrics or high risk can drive HOLD/SELL even if other frameworks are positive.
- **03-ai-moat** — 15%. AI moat (fragile/robust/antifragile) has strong influence, especially for SaaS/AI-exposed names, but does not override the three above when they are negative.
- **04-strategic-moat, 05-sentiment, 06-growth, 07-business** — 6.25% each (25% total). Used to confirm or qualify the verdict, not to override Phase, Metrics, Risk, or AI Moat when those are negative.

## Format and constraints

- **Keys:** Must be the framework IDs: `01-phase`, `02-metrics`, `03-ai-moat`, `04-strategic-moat`, `05-sentiment`, `06-growth`, `07-business`, `08-risk`. All eight should be present if you want every framework to appear in the report and synthesis.
- **Values:** Numbers between 0 and 1. Use decimals (e.g. `0.20`, `0.0625`). The script displays them as whole-number percentages (e.g. 20%, 6%).
- **Sum:** Weights should sum to 1.0. If they don’t, the model still sees the raw percentages; normalization is not applied in the prompt.

## How to adjust the weights

- **Emphasize risk:** Increase `08-risk` (e.g. to 0.25) and decrease one or more of the others so the sum stays 1.0. High risk will then more often drive downgrades.
- **Emphasize AI moat:** Increase `03-ai-moat` (e.g. to 0.20) and reduce supporting frameworks. AI-moat verdicts will matter more in conflicts.
- **Flatten differences:** Give all eight frameworks equal weight (0.125 each). Conflicts will be resolved more evenly rather than by a clear hierarchy.
- **Demote sentiment:** Lower `05-sentiment` (e.g. to 0.03) and spread the difference to Phase, Metrics, or Risk. Sentiment will act more as confirmation than as a driver.

After editing `framework-weights.json`, re-run the pipeline or synthesis; the new weights are read at runtime and injected into the prompt and report.
