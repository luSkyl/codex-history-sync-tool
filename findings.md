# Findings

- Issue #2 reports that newer Codex Desktop can rebuild or filter thread metadata from rollout JSONL `session_meta.payload.model_provider`, so updating only `state_5.sqlite.threads.model_provider` is insufficient.
- Current backend only defines `config.toml`, `state_5.sqlite`, and `history_sync_backups` paths.
- Current backup and restore only handle SQLite `.bak` files.
- Existing tests cover SQLite provider/model sync and SQLite-only restore, but do not create rollout files.
- 2026-04-26: Current real status before optimization showed all SQLite threads already under provider `Linghu`, while 236 threads still had non-current models. Latest pre-sync snapshot confirms the prior provider spread was OpenAI/openai/sub2api/custom/Linghu, and the tool normalized provider metadata rather than deleting sessions.
- 2026-04-26: Refresh slowness was dominated by rollout scanning: 285 rollout files total about 1.75GB; `build_rollout_status()` took about 7346ms of an 8146ms `status` run because `read_rollout_meta()` read whole JSONL files to find the `session_meta` record.
- 2026-04-26: Selective recovery should sort by `updated_at_ms`/`updated_at`; real data has 236 recoverable `Linghu` threads with old models, and the newest default 20 are all old-model candidates.
- 2026-04-26: Candidate titles can contain characters outside the active Windows console encoding; JSON CLI output must use ASCII escapes so PowerShell can capture and `ConvertFrom-Json` reliably.
- 2026-04-26: Codex can rewrite SQLite model values from rollout `turn_context.payload.model` and `turn_context.payload.collaboration_mode.settings.model`, not only `session_meta`; selective sync must update those structured fields too.
