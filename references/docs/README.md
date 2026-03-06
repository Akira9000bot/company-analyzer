# Reference documentation

Guides and specs for the company-analyzer skill. Scripts read config from `references/` (e.g. `framework-weights.json`, `prompts/`); these docs explain how they work.

| Doc | Purpose |
|-----|---------|
| **earnings-url.README.md** | How the earnings press-release URL is chosen (env → file → auto-discovery) and what gets extracted (GAAP/Non-GAAP margin, RPO, etc.). |
| **data-shape-and-frameworks.README.md** | How `*_data.json` is built and which frameworks see which data; keeps prompts and `fetch_data.sh` in sync. |
| **framework-weights.README.md** | How `framework-weights.json` controls synthesis and report ordering; how to adjust weights. |
