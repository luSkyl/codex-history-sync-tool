from __future__ import annotations

import os
import sqlite3
import tempfile
import unittest
import json
from contextlib import closing
from pathlib import Path

from sync_backend import (
    get_status,
    get_sync_candidates,
    make_backup,
    resolve_paths,
    restore_backup,
    sync_to_current_provider,
)


def write_config(codex_home, provider: str = "new_provider", model: str = "gpt-new") -> None:
    (codex_home / "config.toml").write_text(
        f'model_provider = "{provider}"\nmodel = "{model}"\n',
        encoding="utf-8",
    )


def create_threads_db(codex_home, *, with_model: bool = True) -> None:
    conn = sqlite3.connect(codex_home / "state_5.sqlite")
    if with_model:
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT)")
        conn.executemany(
            "INSERT INTO threads (id, model_provider, model) VALUES (?, ?, ?)",
            [
                ("old-provider-old-model", "old_provider", "gpt-old"),
                ("new-provider-old-model", "new_provider", "gpt-old"),
                ("already-current", "new_provider", "gpt-new"),
            ],
        )
    else:
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL)")
        conn.executemany(
            "INSERT INTO threads (id, model_provider) VALUES (?, ?)",
            [
                ("old-provider", "old_provider"),
                ("already-current", "new_provider"),
            ],
        )
    conn.commit()
    conn.close()


def create_ordered_threads_db(codex_home, count: int = 25) -> None:
    conn = sqlite3.connect(codex_home / "state_5.sqlite")
    conn.execute(
        """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            model_provider TEXT NOT NULL,
            model TEXT,
            title TEXT NOT NULL,
            cwd TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            created_at_ms INTEGER,
            updated_at_ms INTEGER,
            rollout_path TEXT
        )
        """
    )
    rows = []
    for index in range(count):
        rows.append(
            (
                f"old-{index:02d}",
                "new_provider",
                "gpt-old",
                f"Old thread {index:02d}",
                "E:\\App\\demo",
                1000 + index,
                2000 + index,
                (1000 + index) * 1000,
                (2000 + index) * 1000,
                f"sessions/rollout-old-{index:02d}.jsonl",
            )
        )
    rows.append(
        (
            "already-current",
            "new_provider",
            "gpt-new",
            "Already current",
            "E:\\App\\demo",
            5000,
            5000,
            5000000,
            5000000,
            "sessions/rollout-current.jsonl",
        )
    )
    conn.executemany(
        """
        INSERT INTO threads
            (id, model_provider, model, title, cwd, created_at, updated_at, created_at_ms, updated_at_ms, rollout_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    conn.commit()
    conn.close()


def write_rollout(
    codex_home: Path,
    thread_id: str,
    provider: str,
    model: str | None,
    *,
    archived: bool = False,
    turn_context_model: str | None = None,
) -> Path:
    root = codex_home / ("archived_sessions" if archived else "sessions") / "2026" / "04" / "26"
    root.mkdir(parents=True, exist_ok=True)
    path = root / f"rollout-{thread_id}.jsonl"
    meta = {
        "type": "session_meta",
        "payload": {
            "id": thread_id,
            "model_provider": provider,
            "cwd": "E:\\App\\demo",
        },
    }
    if model is not None:
        meta["payload"]["model"] = model
    records = [meta]
    if turn_context_model is not None:
        records.append(
            {
                "type": "turn_context",
                "payload": {
                    "model": turn_context_model,
                    "collaboration_mode": {"settings": {"model": turn_context_model}},
                },
            }
        )
    records.append({"type": "response_item", "payload": {"text": "keep me unchanged"}})
    path.write_text(
        "".join(json.dumps(record, separators=(",", ":")) + "\n" for record in records),
        encoding="utf-8",
    )
    return path


def read_rollout_lines(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


class SyncBackendTests(unittest.TestCase):
    def test_sync_updates_provider_and_model_for_newer_codex_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["provider_movable_threads"], 1)
            self.assertEqual(status["model_movable_threads"], 2)
            self.assertEqual(status["movable_threads"], 2)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["synced_fields"], ["model_provider", "model"])
            self.assertEqual(result["updated_rows"], 2)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model"
                ).fetchall()

            self.assertEqual(rows, [("new_provider", "gpt-new", 3)])

    def test_sync_updates_matching_rollout_session_meta(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            old_rollout = write_rollout(codex_home, "old-provider-old-model", "old_provider", "gpt-old")
            current_rollout = write_rollout(codex_home, "already-current", "new_provider", "gpt-new")
            unrelated_rollout = write_rollout(codex_home, "not-in-db", "old_provider", "gpt-old", archived=True)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["rollout_total"], 3)
            self.assertEqual(status["rollout_db_mismatch_threads"], 0)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["updated_rollout_files"], 1)
            old_lines = read_rollout_lines(old_rollout)
            current_lines = read_rollout_lines(current_rollout)
            unrelated_lines = read_rollout_lines(unrelated_rollout)

            self.assertEqual(old_lines[0]["payload"]["model_provider"], "new_provider")
            self.assertEqual(old_lines[0]["payload"]["model"], "gpt-new")
            self.assertEqual(old_lines[1]["payload"]["text"], "keep me unchanged")
            self.assertEqual(current_lines[0]["payload"]["model_provider"], "new_provider")
            self.assertEqual(unrelated_lines[0]["payload"]["model_provider"], "old_provider")

            status_after = get_status(paths)
            self.assertEqual(status_after["rollout_db_mismatch_threads"], 0)

    def test_candidate_list_defaults_to_newest_twenty(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_ordered_threads_db(codex_home, count=25)
            paths = resolve_paths(str(codex_home))

            result = get_sync_candidates(paths, limit=25)

            self.assertEqual(result["total_candidates"], 25)
            self.assertEqual(result["default_selected_count"], 20)
            self.assertEqual(result["default_selected_thread_ids"][0], "old-24")
            self.assertEqual(result["default_selected_thread_ids"][-1], "old-05")
            self.assertEqual(result["candidates"][0]["title"], "Old thread 24")
            self.assertTrue(result["candidates"][0]["can_sync"])

    def test_candidate_list_can_include_current_threads_as_read_only_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_ordered_threads_db(codex_home, count=25)
            paths = resolve_paths(str(codex_home))

            result = get_sync_candidates(paths, limit=30, include_current=True)

            self.assertEqual(result["total_threads"], 26)
            self.assertEqual(result["total_candidates"], 25)
            self.assertEqual(result["current_count"], 1)
            self.assertEqual(result["total_displayed"], 26)
            self.assertEqual(result["candidates"][0]["id"], "already-current")
            self.assertFalse(result["candidates"][0]["can_sync"])
            self.assertEqual(result["candidates"][0]["status"], "当前")
            self.assertEqual(result["default_selected_thread_ids"][0], "old-24")
            self.assertNotIn("already-current", result["default_selected_thread_ids"])

    def test_candidate_list_default_limit_is_one_thousand_and_newest_first(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_ordered_threads_db(codex_home, count=1005)
            paths = resolve_paths(str(codex_home))

            result = get_sync_candidates(paths)

            self.assertEqual(result["total_candidates"], 1005)
            self.assertEqual(result["limit"], 1000)
            self.assertEqual(len(result["candidates"]), 1000)
            self.assertEqual(result["candidates"][0]["id"], "old-1004")
            self.assertEqual(result["candidates"][-1]["id"], "old-05")
            self.assertEqual(result["default_selected_thread_ids"][0], "old-1004")
            self.assertEqual(result["default_selected_thread_ids"][-1], "old-985")

    def test_candidate_list_uses_updated_time_before_created_time(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            conn = sqlite3.connect(codex_home / "state_5.sqlite")
            conn.execute(
                """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    model_provider TEXT NOT NULL,
                    model TEXT,
                    title TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    created_at_ms INTEGER,
                    updated_at_ms INTEGER,
                    rollout_path TEXT
                )
                """
            )
            conn.executemany(
                """
                INSERT INTO threads
                    (id, model_provider, model, title, cwd, created_at, updated_at, created_at_ms, updated_at_ms, rollout_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    ("created-today", "new_provider", "gpt-old", "Created today", "E:\\App\\demo", 3000, 8000, 3000000, 8000000, None),
                    ("continued-today", "new_provider", "gpt-old", "Continued today", "E:\\App\\demo", 1000, 9000, 1000000, 9000000, None),
                ],
            )
            conn.commit()
            conn.close()
            paths = resolve_paths(str(codex_home))

            result = get_sync_candidates(paths, limit=2)

            self.assertEqual([row["id"] for row in result["candidates"]], ["continued-today", "created-today"])

    def test_candidate_list_uses_rollout_modified_time_like_codex_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            plugin_newer_rollout = write_rollout(codex_home, "plugin-newer", "new_provider", "gpt-old")
            db_newer_rollout = write_rollout(codex_home, "db-newer", "new_provider", "gpt-old")
            os.utime(plugin_newer_rollout, (12000, 12000))
            os.utime(db_newer_rollout, (11000, 11000))
            conn = sqlite3.connect(codex_home / "state_5.sqlite")
            conn.execute(
                """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    model_provider TEXT NOT NULL,
                    model TEXT,
                    title TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    created_at_ms INTEGER,
                    updated_at_ms INTEGER,
                    rollout_path TEXT
                )
                """
            )
            conn.executemany(
                """
                INSERT INTO threads
                    (id, model_provider, model, title, cwd, created_at, updated_at, created_at_ms, updated_at_ms, rollout_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        "plugin-newer",
                        "new_provider",
                        "gpt-old",
                        "Plugin newer",
                        "E:\\App\\demo",
                        1000,
                        8000,
                        1000000,
                        8000000,
                        str(plugin_newer_rollout),
                    ),
                    (
                        "db-newer",
                        "new_provider",
                        "gpt-old",
                        "DB newer",
                        "E:\\App\\demo",
                        1000,
                        9000,
                        1000000,
                        9000000,
                        str(db_newer_rollout),
                    ),
                ],
            )
            conn.commit()
            conn.close()
            paths = resolve_paths(str(codex_home))

            result = get_sync_candidates(paths, limit=2)

            self.assertEqual([row["id"] for row in result["candidates"]], ["plugin-newer", "db-newer"])
            self.assertEqual(result["candidates"][0]["activity_source"], "rollout_mtime")
            self.assertEqual(result["candidates"][0]["activity_at_ms"], 12000000)

    def test_sync_only_updates_selected_thread_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            selected_rollout = write_rollout(codex_home, "old-provider-old-model", "old_provider", "gpt-old")
            unselected_rollout = write_rollout(codex_home, "new-provider-old-model", "new_provider", "gpt-old")
            paths = resolve_paths(str(codex_home))

            result = sync_to_current_provider(paths, ["old-provider-old-model"])

            self.assertEqual(result["updated_rows"], 1)
            self.assertEqual(result["selected_thread_ids"], ["old-provider-old-model"])
            self.assertEqual(result["updated_rollout_files"], 1)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = dict(
                    conn.execute(
                        "SELECT id, model_provider || ':' || model FROM threads ORDER BY id"
                    ).fetchall()
                )

            self.assertEqual(rows["old-provider-old-model"], "new_provider:gpt-new")
            self.assertEqual(rows["new-provider-old-model"], "new_provider:gpt-old")
            self.assertEqual(read_rollout_lines(selected_rollout)[0]["payload"]["model"], "gpt-new")
            self.assertEqual(read_rollout_lines(unselected_rollout)[0]["payload"]["model"], "gpt-old")

    def test_selected_sync_adds_missing_rollout_model_for_current_db_thread(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            rollout = write_rollout(codex_home, "already-current", "new_provider", None)
            paths = resolve_paths(str(codex_home))

            result = sync_to_current_provider(paths, ["already-current"])

            self.assertEqual(result["updated_rows"], 0)
            self.assertEqual(result["updated_rollout_files"], 1)
            self.assertEqual(read_rollout_lines(rollout)[0]["payload"]["model"], "gpt-new")

    def test_selected_sync_updates_rollout_turn_context_model(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            rollout = write_rollout(
                codex_home,
                "already-current",
                "new_provider",
                "gpt-new",
                turn_context_model="gpt-old",
            )
            paths = resolve_paths(str(codex_home))

            result = sync_to_current_provider(paths, ["already-current"])

            self.assertEqual(result["updated_rows"], 0)
            self.assertEqual(result["updated_rollout_files"], 1)
            lines = read_rollout_lines(rollout)
            self.assertEqual(lines[1]["payload"]["model"], "gpt-new")
            self.assertEqual(lines[1]["payload"]["collaboration_mode"]["settings"]["model"], "gpt-new")

    def test_sync_still_supports_legacy_schema_without_model_column(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=False)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["provider_movable_threads"], 1)
            self.assertIsNone(status["model_movable_threads"])
            self.assertEqual(status["movable_threads"], 1)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["synced_fields"], ["model_provider"])
            self.assertEqual(result["updated_rows"], 1)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute("SELECT model_provider, COUNT(*) FROM threads GROUP BY model_provider").fetchall()

            self.assertEqual(rows, [("new_provider", 2)])

    def test_restore_backup_restores_previous_database_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")

            sync_to_current_provider(paths)
            result = restore_backup(paths, str(backup_path))

            self.assertEqual(result["restored_from"], str(backup_path))
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model ORDER BY model_provider, model"
                ).fetchall()

            self.assertEqual(
                rows,
                [
                    ("new_provider", "gpt-new", 1),
                    ("new_provider", "gpt-old", 1),
                    ("old_provider", "gpt-old", 1),
                ],
            )

    def test_restore_still_supports_legacy_sqlite_backup_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            paths.backup_dir.mkdir()
            backup_path = paths.backup_dir / "state_5.sqlite.manual.20260101-000000.bak"
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as source:
                with closing(sqlite3.connect(backup_path)) as target:
                    source.backup(target)

            sync_to_current_provider(paths)
            result = restore_backup(paths, str(backup_path))

            self.assertEqual(result["restored_from"], str(backup_path))
            self.assertEqual(result["restored_rollout_files"], 0)
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model ORDER BY model_provider, model"
                ).fetchall()

            self.assertEqual(
                rows,
                [
                    ("new_provider", "gpt-new", 1),
                    ("new_provider", "gpt-old", 1),
                    ("old_provider", "gpt-old", 1),
                ],
            )

    def test_restore_snapshot_restores_rollout_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            rollout = write_rollout(codex_home, "old-provider-old-model", "old_provider", "gpt-old")
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual", full_rollout=True)

            sync_to_current_provider(paths)
            self.assertEqual(read_rollout_lines(rollout)[0]["payload"]["model_provider"], "new_provider")

            result = restore_backup(paths, str(backup_path))

            self.assertEqual(result["restored_rollout_files"], 1)
            restored_lines = read_rollout_lines(rollout)
            self.assertEqual(restored_lines[0]["payload"]["model_provider"], "old_provider")
            self.assertEqual(restored_lines[0]["payload"]["model"], "gpt-old")


if __name__ == "__main__":
    unittest.main()
