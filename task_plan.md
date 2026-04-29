# Task Plan

Goal: Fix Codex history sync so newer Codex Desktop history metadata stays consistent across SQLite and rollout JSONL files.

## Phases

- [complete] Add planning trace and record initial findings.
- [complete] Implement rollout-aware backend sync, backup, and restore.
- [complete] Add focused unit tests for rollout sync and restore.
- [complete] Update UI and README wording for dual-layer sync.
- [complete] Run verification and record results.
- [complete] Add selective latest-session recovery so sync defaults to chosen recent candidates instead of every old thread.
- [complete] Run final verification and apply default latest-20 recovery to the real Codex state.
- [complete] Expand candidate list loading to 1000 and keep newest sessions first.
- [complete] Fix candidate ordering so recoverable sessions follow Codex plugin activity order.
- [complete] Show current provider/model sessions as read-only rows in the UI and refresh the UI color theme.
- [complete] Support official-account sync when `config.toml` has no `model_provider`.
- [complete] Prevent current-account active sessions from being selected or synced when stale provider metadata remains.
- [complete] Upgrade provider handling to a bidirectional Provider Profile abstraction.
- [complete] Add recoverable trash-first deletion for arbitrary and old sessions.

## Decisions

- Match rollout files by `session_meta.payload.id` against SQLite `threads.id`.
- Rewrite only the `session_meta` JSONL record, preserving all other lines.
- Support old SQLite `.bak` backups and new directory snapshots.
- Prefer rollout file modification time as the newest-session ordering source so recoverable candidates follow the Codex plugin activity order; fall back to `updated_at_ms`/`updated_at` then created time when the rollout file is unavailable.
- Load up to 1000 candidates in the UI so "select all" does not silently miss later candidates in normal local-history volumes.
- Use `list-candidates --include-current` for the UI so the table resembles the Codex session list; only rows marked `can_sync` can be selected or sent to sync.
- Update rollout `turn_context` model fields in addition to `session_meta`; otherwise running Codex can rebuild SQLite back to the old model.
- Treat missing `config.toml` `model_provider` as the official account's providerless target instead of failing; write SQLite `NULL` when allowed, fall back to an empty string for NOT NULL schemas, and remove rollout `session_meta.payload.model_provider`.
- Use `config.toml`/`auth.json` modification time as the current account activation guard; provider/model-mismatched sessions updated after that point are shown as current and excluded from backend sync.
- Use `TargetProviderProfile` as the sync contract: `named_provider` writes provider strings to SQLite/rollout, while `official_providerless` writes schema-safe empty/NULL DB values and omits rollout provider fields.
- Delete operations must be recoverable by default: store SQLite rows and moved rollout files in `history_sync_trash`, and create a safety backup before mutating the live DB.

## Errors Encountered

| Error | Attempt | Resolution |
| --- | --- | --- |
| `UnicodeEncodeError` when piping `list-candidates` JSON through PowerShell | 1 | Changed CLI JSON output to ASCII escapes while preserving decoded values through `ConvertFrom-Json`. |
| DB model reverted after selective sync while Codex was running | 1 | Found old model in rollout `turn_context` records; expanded rollout rewrite to update structured turn context model fields and re-ran selected sync. |
| Continued sessions still looked like yesterday in candidate list | 1 | Restored candidate display fallback to prefer `updated_at_ms`/`updated_at` before created time and added a regression test. |
| Candidate order differed from Codex plugin session order | 1 | Changed candidate ordering/display to prefer rollout file modification time and added a plugin-order regression test. |
| Current official-account session was selectable because stale DB provider was `openai` | 1 | Added a current-account activity guard based on config/auth modification time and enforced it in candidate SQL and selected sync. |
