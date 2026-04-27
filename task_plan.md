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

## Decisions

- Match rollout files by `session_meta.payload.id` against SQLite `threads.id`.
- Rewrite only the `session_meta` JSONL record, preserving all other lines.
- Support old SQLite `.bak` backups and new directory snapshots.
- Prefer rollout file modification time as the newest-session ordering source so recoverable candidates follow the Codex plugin activity order; fall back to `updated_at_ms`/`updated_at` then created time when the rollout file is unavailable.
- Load up to 1000 candidates in the UI so "select all" does not silently miss later candidates in normal local-history volumes.
- Use `list-candidates --include-current` for the UI so the table resembles the Codex session list; only rows marked `can_sync` can be selected or sent to sync.
- Update rollout `turn_context` model fields in addition to `session_meta`; otherwise running Codex can rebuild SQLite back to the old model.

## Errors Encountered

| Error | Attempt | Resolution |
| --- | --- | --- |
| `UnicodeEncodeError` when piping `list-candidates` JSON through PowerShell | 1 | Changed CLI JSON output to ASCII escapes while preserving decoded values through `ConvertFrom-Json`. |
| DB model reverted after selective sync while Codex was running | 1 | Found old model in rollout `turn_context` records; expanded rollout rewrite to update structured turn context model fields and re-ran selected sync. |
| Continued sessions still looked like yesterday in candidate list | 1 | Restored candidate display fallback to prefer `updated_at_ms`/`updated_at` before created time and added a regression test. |
| Candidate order differed from Codex plugin session order | 1 | Changed candidate ordering/display to prefer rollout file modification time and added a plugin-order regression test. |
