# Why Deleting Sessions Fixed KVYO Analysis Failures

## What sessions store

- **`agents/main/sessions/sessions.json`** – Maps each chat (e.g. Telegram) to a session: `sessionId`, `sessionFile` (path to a `.jsonl`), `skillsSnapshot` (cached skill list and prompt), `updatedAt`, `abortedLastRun`, etc.
- **`agents/main/sessions/<uuid>.jsonl`** – Conversation log for that session: every user message and assistant turn (including long outputs and errors) is appended here and used as **context for the next request**.

## Why deleting them fixed the issue

1. **Context bloat → TPM spike and billing**  
   After many failed KVYO runs, the session `.jsonl` contained lots of failed attempts, long error messages, and heartbeat alerts. Each new `/analyze` request sent **all of that history** to the model as context. That:
   - Drove **input tokens per request** (and per minute) way up, contributing to the **1M TPM spike** and billing/limit errors.
   - Could make the agent repeat the same failing flow (e.g. “retry analysis”) instead of starting clean.

2. **Stale or bad state**  
   `sessions.json` and the session files can hold:
   - Cached **skillsSnapshot** (skill list and paths). If something was updated or paths changed, the cache could point to the wrong place or an old version.
   - Flags like **abortedLastRun** or internal state that kept the agent in a “failure” or retry loop.
   - **Corrupted or half-written data** if a run crashed mid-write, so the next run would read bad state and fail again.

   Deleting sessions forced a **fresh session** and a **fresh skills snapshot**, so the next run had clean state and no long failure history.

## How to prevent this in the future

1. **Treat sessions as disposable when things get stuck**  
   If `/analyze` (or any heavy skill) keeps failing with the same error:
   - **Quick fix:** Delete session data so the next run starts with empty context and fresh state:
     - Remove `agents/main/sessions/sessions.json`
     - Remove `agents/main/sessions/*.jsonl`
   - Or add a “Reset session” / “Clear context” action in the agent if it exists.

2. **Avoid unbounded context in one thread**  
   For heavy, repeated runs (e.g. many analyses in one chat):
   - Start a **new chat/session** for a new batch of analyses, or
   - Periodically **clear or trim** the session `.jsonl` (e.g. keep only the last N turns) so old failures and long outputs don’t keep getting sent every time.

3. **Session hygiene (optional)**  
   - Periodically archive or delete old `.jsonl` files (e.g. sessions not used in 7 days).
   - Or document a cron/maintenance step that trims session history for sessions that have grown very large (e.g. by line count or token estimate).

4. **Pipeline-side safeguards (already in place)**  
   - 45s cooldown between analysis steps to reduce TPM spikes.
   - Billing/402–403 handling and clear error messages.
   - Pipeline continues after a failed step and builds a partial report.

**TL;DR:** Sessions persist full conversation history and cached state. After many failed runs, that history blew up context and helped cause TPM/billing issues and repeated failures. Deleting sessions cleared the history and state so the next run started clean. To prevent recurrence: clear or trim sessions when analysis gets stuck, avoid doing many heavy runs in one long thread without resetting, and optionally add periodic session hygiene.
