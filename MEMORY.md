# MEMORY.md - Long-Term Memory

## Personal Context (Dan)
- **Profession:** Software Engineer (Backend/Platform, Spring/Kotlin).
- **Status:** Unemployed, seeking remote roles (Target: April 2026).
- **Location:** Huntington Beach, CA.
- **Interests:** AI Agents, Investing (AI Moats), Thrifting, Surfing, Running.
- **Recent Experience:** Camino de Santiago (Oct 2025).

## System Protocols & Decisions

### Context Management (Established 2026-02-25)
- **Problem:** Gemini 3 Flash TPM limits are hit when the `main` session grows too large (~1M tokens).
- **Protocol:**
  1. **Isolated Heartbeats:** Heartbeats run in a separate `heartbeat` session to avoid loading main history.
  2. **Daily Resets:** The `main` session auto-resets daily at 04:00 UTC.
  3. **Reset Interlock:** The hourly heartbeat performs a "Pre-Reset Distillation" during the 03:00 UTC hour to capture mistakes and takeaways before the wipe.
  4. **Mandatory Distillation:** Before any reset or manual clearing, key takeaways MUST be written to `MEMORY.md` or a daily log.
  5. **Aggressive Pruning:** Context TTL is set to 15m to clear cache during idle time.
  6. **Muted Heartbeats (2026-03-04):** Heartbeat cron delivery set to `none`. Notifications only occur via `message` tool on state changes (Delta Rule).

### Skills & Tools
- **Company Analyzer:** Specialized tool for investment research (MELI, NET, SNOW, etc.). Optimization work done in Feb 2026 to reduce per-analysis costs. 
  - **Chain of Thought (CoT):** Implemented rolling `SUMMARY_CONTEXT` (hand-off) between frameworks to ensure logical consistency (e.g., Phase-based scoring in metrics).
  - **Unified Client:** Unified all scripts to use the Google Gemini 3 Flash client for reliability and cost tracking.
- **Privacy/Storage Protocol (2026-02-27):** Do NOT commit skill analysis results (e.g., individual company buy/hold ratings or dossiers) to MEMORY.md. Keep results in local skill assets only.

## Ongoing Todos
- [x] Monitor Gemini 3 Flash TPM levels after heartbeat isolation. (Fixed: Daily resets + isolated heartbeats stabilized TPM; see 2026-03-04 log).
- [ ] Resume job search automation/research.
- [ ] Update `company-analyzer` scripts to be path-agnostic.
- [x] Commit pending memory files. (Fixed: All memory files are tracked and committed).
- [x] Resolve uncommitted changes in `skills/company-analyzer`. (Fixed: Branch is synced with origin/main).
- [x] Investigate and fix `analyze-pipeline.sh` syntax error at line 76. (Fixed: Verified syntax and step order; confirmed functional).
- [x] Fix the syntax error in `analyze-pipeline.sh` properly.
- [x] Resolve Git divergence and hygiene issues. (Fixed: Repositories are synced and clean as of Mar 8).
- [ ] Monitor Gemini 3 Flash stability (00:00-03:00 UTC window).


## Investment Research (Feb-Mar 2026)
- **KVYO (Klaviyo):** Phase 3 (Self-Funding). High Conviction. Moat: Usage-based pricing (AI contraction hedge).
- **NET (Cloudflare) / SNOW (Snowflake):** Completed analysis Mar 7-8. (Results in local assets).
- **Gemini 503 Instability (2026-03-05):** Gemini 3 Flash exhibits persistent 503 errors during 00:00-03:00 UTC, specifically impacting the `02-metrics` framework. Stability improved Mar 7-8.
- **Model Configuration (2026-03-09):** Pruned `gemini-1.5-flash` from gateway config; exclusively using `gemini-3-flash` and `gemini-3.1-flash-lite`.
- **Analysis Progress:** Completed AMPX, TXN, DDOG, ADBE, MELI, CRM, FSLY, NET, SNOW, and META. Research in progress for AAPL, MU, and TEAM (Mar 9).
- Company analysis findings are stored in local skill assets (see Privacy Protocol).

## Daily Distillation (2026-03-09)
- **Configuration:** Successfully standardized LLM usage to Gemini 3 Flash and 3.1 Flash Lite. All deprecated 1.5/2.0 references have been purged.
- **Research:** AAPL, MU, and TEAM analyses are in progress.
- **System Maintenance:** Implemented routine Pre-Reset Distillation to stabilize system state prior to 04:00 daily resets.
- **Reset Check:** Pre-reset distillation verified and written to daily log for Mar 9.

## Daily Distillation (2026-03-17)
- **Pre-Reset Maintenance:** System stable; no tool failures or loops.
- **Git Hygiene:** Clean; repo synced with origin/master.
- **Reset Interlock (03:00 UTC):** Pre-reset check complete. Data distilled. Ready for 04:00 UTC reset.



