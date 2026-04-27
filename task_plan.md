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

## Decisions

- Match rollout files by `session_meta.payload.id` against SQLite `threads.id`.
- Rewrite only the `session_meta` JSONL record, preserving all other lines.
- Support old SQLite `.bak` backups and new directory snapshots.
- Use `updated_at_ms`/`updated_at` as the newest-session ordering source; default UI selection is the newest 20 candidate threads.
- Load up to 1000 candidates in the UI so "select all" does not silently miss later candidates in normal local-history volumes.
- Update rollout `turn_context` model fields in addition to `session_meta`; otherwise running Codex can rebuild SQLite back to the old model.

## Errors Encountered

| Error | Attempt | Resolution |
| --- | --- | --- |
| `UnicodeEncodeError` when piping `list-candidates` JSON through PowerShell | 1 | Changed CLI JSON output to ASCII escapes while preserving decoded values through `ConvertFrom-Json`. |
| DB model reverted after selective sync while Codex was running | 1 | Found old model in rollout `turn_context` records; expanded rollout rewrite to update structured turn context model fields and re-ran selected sync. |
