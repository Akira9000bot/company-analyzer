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
- [ ] Commit 5 days of pending memory files (Mar 1-5).
- [ ] Resolve uncommitted changes in `skills/company-analyzer`.


## Investment Research (Feb-Mar 2026)
- **KVYO (Klaviyo):** Phase 3 (Self-Funding). High Conviction. Moat: Usage-based pricing (AI contraction hedge).
- **Gemini 503 Instability (2026-03-05):** Gemini 3 Flash exhibits persistent 503 errors during 00:00-03:00 UTC, specifically impacting the `02-metrics` framework.
- Company analysis findings are stored in local skill assets (see Privacy Protocol).
