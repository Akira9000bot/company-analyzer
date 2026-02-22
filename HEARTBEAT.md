# HEARTBEAT.md

## On Wake / Heartbeat Tasks

### 1. Routine System Check (Single Thread)

**CRITICAL INSTRUCTION: DO NOT SPAWN SUB-AGENTS.** You must execute all tasks sequentially within this single heartbeat session to conserve API compute budget. 

When the heartbeat fires, perform a fast, lightweight review:

1. **Mistake Review:** Briefly scan `memory/YYYY-MM-DD.md` (last 2 days) for any obvious errors, infinite loops, or lessons learned. Append brief bullet points to `memory/heartbeat-review.md`.
2. **Skill Check:** Perform a surface-level scan of the `skills/` directory for obvious errors or broken files.
3. **Workspace Maintenance:** Flag any orphaned temp files in `assets/outputs/` or uncommitted Git changes.
4. **Memory Consolidation:** Briefly note any glaringly outdated info in `MEMORY.md` that needs archiving.

Do not over-analyze. Complete this entire checklist in a single, concise response using minimal tokens. 

**Model:** `google/gemini-2.0-flash-lite`

---

# Keep below line empty to skip other heartbeat tasks