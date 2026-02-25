# HEARTBEAT.md

## On Wake / Heartbeat Tasks

### 1. Routine System Check (Single Thread)

**CRITICAL INSTRUCTION: DO NOT SPAWN SUB-AGENTS.** You must execute all tasks sequentially within this single heartbeat session to conserve API compute budget. 

When the heartbeat fires, perform a fast, lightweight review:

1.  **Mistake Review:** Briefly scan `memory/YYYY-MM-DD.md` (last 2 days) for any NEW errors, infinite loops, or lessons learned since your last check. 
2.  **Reset Interlock (03:00-04:00 UTC):**
    *   If current time is in the 03:xx hour, perform **Pre-Reset Distillation**.
    *   Summarize the day's key takeaways, mistakes, and project progress.
    *   Ensure these are written to `MEMORY.md` or the `Daily Distillation` block in the log before the 04:00 reset.
3.  **Distillation Sync:** Verify that a `## Daily Distillation` block exists in `memory/YYYY-MM-DD.md` for the previous day. Flag as `Protocol Failure` if missing after a 04:00 reset.
4.  **Skill Check:** Perform a surface-level scan of the `skills/` directory for obvious errors or broken files.
5.  **Workspace Maintenance:** Flag any NEW orphaned temp files in `assets/outputs/` or uncommitted Git changes.
6.  **Memory Consolidation:** Briefly note any glaringly outdated info in `MEMORY.md` that needs archiving.

**Delta Rule:** Only report NEW issues or state changes (and append them to `memory/heartbeat-review.md`). If all checks are clear and nothing has changed since the last run, reply EXACTLY: HEARTBEAT_OK.

Do not provide a "summary of current state" if the state is unchanged. Do not repeat prior warnings if they have not evolved. Complete this checklist in a single, concise response using minimal tokens. 

**Model:** `google/gemini-3-flash-preview`

---

# Keep below line empty to skip other heartbeat tasks