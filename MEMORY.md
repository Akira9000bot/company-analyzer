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

### Skills & Tools
- **Company Analyzer:** Specialized tool for investment research (MELI, NET, SNOW, etc.). Optimization work done in Feb 2026 to reduce per-analysis costs.

## Ongoing Todos
- [ ] Monitor Gemini 3 Flash TPM levels after heartbeat isolation.
- [ ] Resume job search automation/research.
