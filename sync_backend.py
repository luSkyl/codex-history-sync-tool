from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import shutil
from collections import Counter, OrderedDict
from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

SNAPSHOT_VERSION = 1
DEFAULT_SELECTED_CANDIDATES = 20
DEFAULT_CANDIDATE_LIST_LIMIT = 1000


def default_codex_home() -> Path:
    return Path.home() / ".codex"


@dataclass
class Paths:
    codex_home: Path
    config_path: Path
    db_path: Path
    backup_dir: Path
    sessions_dir: Path
    archived_sessions_dir: Path


def resolve_paths(codex_home: str | None) -> Paths:
    home = Path(codex_home).expanduser() if codex_home else default_codex_home()
    return Paths(
        codex_home=home,
        config_path=home / "config.toml",
        db_path=home / "state_5.sqlite",
        backup_dir=home / "history_sync_backups",
        sessions_dir=home / "sessions",
        archived_sessions_dir=home / "archived_sessions",
    )


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_current_provider(config_text: str) -> str:
    match = re.search(r'(?m)^\s*model_provider\s*=\s*"([^"]+)"', config_text)
    if not match:
        raise RuntimeError("Could not find model_provider in config.toml.")
    return match.group(1)


def parse_current_model(config_text: str) -> str | None:
    match = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"', config_text)
    return match.group(1) if match else None


@contextmanager
def connect_db(path: Path, readonly: bool = False) -> Iterator[sqlite3.Connection]:
    if readonly:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
    else:
        conn = sqlite3.connect(str(path), timeout=30)
        conn.execute("PRAGMA busy_timeout = 30000")
    try:
        yield conn
    finally:
        conn.close()


def get_thread_columns(conn: sqlite3.Connection) -> set[str]:
    return {str(row[1]) for row in conn.execute("PRAGMA table_info(threads)")}


def ensure_environment(paths: Paths) -> None:
    if not paths.config_path.exists():
        raise RuntimeError(f"Missing config file: {paths.config_path}")
    if not paths.db_path.exists():
        raise RuntimeError(f"Missing database file: {paths.db_path}")


@dataclass
class RolloutMeta:
    path: Path
    line_index: int
    record: dict[str, object]
    thread_id: str
    model_provider: str | None
    model: str | None


def iter_rollout_paths(paths: Paths) -> Iterator[Path]:
    seen: set[Path] = set()
    for root in (paths.sessions_dir, paths.archived_sessions_dir):
        if not root.exists():
            continue
        for path in sorted(root.rglob("rollout-*.jsonl")):
            resolved = path.resolve()
            if resolved not in seen and path.is_file():
                seen.add(resolved)
                yield path


def extract_payload(record: object) -> dict[str, object] | None:
    if not isinstance(record, dict):
        return None
    if record.get("type") != "session_meta":
        return None
    payload = record.get("payload")
    return payload if isinstance(payload, dict) else None


def read_rollout_meta(path: Path) -> RolloutMeta | None:
    with path.open("r", encoding="utf-8-sig") as handle:
        for index, line in enumerate(handle):
            meta = parse_rollout_meta_line(path, index, line)
            if meta is not None:
                return meta
    return None


def parse_rollout_meta_line(path: Path, index: int, line: str) -> RolloutMeta | None:
    stripped = line.strip()
    if not stripped:
        return None
    try:
        record = json.loads(stripped)
    except json.JSONDecodeError:
        return None
    payload = extract_payload(record)
    if payload is None:
        return None
    thread_id = payload.get("id")
    if not isinstance(thread_id, str) or not thread_id:
        return None
    provider = payload.get("model_provider")
    model = payload.get("model")
    return RolloutMeta(
        path=path,
        line_index=index,
        record=record,
        thread_id=thread_id,
        model_provider=provider if isinstance(provider, str) else None,
        model=model if isinstance(model, str) else None,
    )


def query_thread_metadata(conn: sqlite3.Connection) -> dict[str, dict[str, str | None]]:
    columns = get_thread_columns(conn)
    select_parts = ["id", "model_provider"]
    if "model" in columns:
        select_parts.append("model")
    rows: dict[str, dict[str, str | None]] = {}
    for row in conn.execute(f"SELECT {', '.join(select_parts)} FROM threads"):
        thread_id = str(row[0])
        rows[thread_id] = {
            "model_provider": str(row[1]) if row[1] is not None else None,
            "model": str(row[2]) if "model" in columns and row[2] is not None else None,
        }
    return rows


def query_sync_candidate_thread_ids(
    conn: sqlite3.Connection,
    *,
    current_provider: str,
    current_model: str | None,
    columns: set[str],
    thread_ids: Iterable[str] | None = None,
) -> set[str]:
    where_sql, params = build_sync_candidate_condition(current_provider, current_model, columns)
    where_sql, params = add_thread_id_filter(where_sql, params, thread_ids)
    return {str(row[0]) for row in conn.execute(f"SELECT id FROM threads WHERE {where_sql}", params)}


def build_sync_candidate_condition(
    current_provider: str,
    current_model: str | None,
    columns: set[str],
) -> tuple[str, list[str]]:
    where_parts = ["model_provider IS NULL OR model_provider <> ?"]
    params: list[str] = [current_provider]
    if "model" in columns and current_model:
        where_parts.append("model IS NULL OR model <> ?")
        params.append(current_model)
    where_sql = " OR ".join(f"({part})" for part in where_parts)
    return where_sql, params


def normalized_thread_ids(thread_ids: Iterable[str] | None) -> list[str]:
    if thread_ids is None:
        return []
    output = []
    seen = set()
    for thread_id in thread_ids:
        value = str(thread_id).strip()
        if not value or value in seen:
            continue
        seen.add(value)
        output.append(value)
    return output


def add_thread_id_filter(
    where_sql: str,
    params: list[str],
    thread_ids: Iterable[str] | None,
) -> tuple[str, list[str]]:
    selected_ids = normalized_thread_ids(thread_ids)
    if not selected_ids:
        return where_sql, params
    placeholders = ", ".join("?" for _ in selected_ids)
    return f"({where_sql}) AND id IN ({placeholders})", [*params, *selected_ids]


def resolve_rollout_path(paths: Paths, rollout_path: str | None) -> Path | None:
    if not rollout_path:
        return None
    path = Path(rollout_path)
    return path if path.is_absolute() else paths.codex_home / path


def thread_activity_time_ms(row: dict[str, object]) -> int:
    for key, multiplier in (
        ("updated_at_ms", 1),
        ("updated_at", 1000),
        ("created_at_ms", 1),
        ("created_at", 1000),
    ):
        value = row.get(key)
        if value is not None:
            return int(value) * multiplier
    return 0


def rollout_modified_time_ms(paths: Paths, rollout_path: str | None) -> int | None:
    path = resolve_rollout_path(paths, rollout_path)
    if path is None:
        return None
    try:
        return int(path.stat().st_mtime * 1000)
    except OSError:
        return None


def apply_thread_activity_time(paths: Paths, row: dict[str, object]) -> dict[str, object]:
    rollout_time_ms = rollout_modified_time_ms(paths, row.get("rollout_path"))
    if rollout_time_ms is not None:
        row["activity_at_ms"] = rollout_time_ms
        row["activity_source"] = "rollout_mtime"
    else:
        row["activity_at_ms"] = thread_activity_time_ms(row)
        row["activity_source"] = "thread_metadata"
    return row


def is_sync_candidate_row(row: dict[str, object], current_provider: str, current_model: str | None, columns: set[str]) -> bool:
    if row.get("model_provider") != current_provider:
        return True
    if "model" in columns and current_model and row.get("model") != current_model:
        return True
    return False


def optional_column(columns: set[str], column: str) -> str:
    return column if column in columns else f"NULL AS {column}"


def query_sync_candidates(
    conn: sqlite3.Connection,
    *,
    paths: Paths,
    current_provider: str,
    current_model: str | None,
    columns: set[str],
    limit: int | None = DEFAULT_CANDIDATE_LIST_LIMIT,
    include_current: bool = False,
) -> list[dict[str, object]]:
    if limit is not None and limit <= 0:
        return []
    candidate_where_sql, params = build_sync_candidate_condition(current_provider, current_model, columns)
    where_sql = "1 = 1" if include_current else candidate_where_sql
    select_parts = [
        "id",
        optional_column(columns, "title"),
        "model_provider",
        optional_column(columns, "model"),
        optional_column(columns, "cwd"),
        optional_column(columns, "created_at"),
        optional_column(columns, "updated_at"),
        optional_column(columns, "created_at_ms"),
        optional_column(columns, "updated_at_ms"),
        optional_column(columns, "rollout_path"),
    ]
    sql = f"""
        SELECT {', '.join(select_parts)}
        FROM threads
        WHERE {where_sql}
        ORDER BY id DESC
    """
    query_params: list[object] = [] if include_current else [*params]

    rows = []
    for row in conn.execute(sql, query_params):
        thread_row = {
            "id": str(row[0]),
            "title": str(row[1]) if row[1] else "",
            "model_provider": str(row[2]) if row[2] is not None else None,
            "model": str(row[3]) if row[3] is not None else None,
            "cwd": str(row[4]) if row[4] is not None else None,
            "created_at": int(row[5]) if row[5] is not None else None,
            "updated_at": int(row[6]) if row[6] is not None else None,
            "created_at_ms": int(row[7]) if row[7] is not None else None,
            "updated_at_ms": int(row[8]) if row[8] is not None else None,
            "rollout_path": str(row[9]) if row[9] is not None else None,
        }
        can_sync = is_sync_candidate_row(thread_row, current_provider, current_model, columns)
        thread_row["can_sync"] = can_sync
        thread_row["status"] = "可同步" if can_sync else "当前"
        rows.append(
            apply_thread_activity_time(
                paths,
                thread_row,
            )
        )
    rows.sort(
        key=lambda row: (
            int(row["activity_at_ms"]) if row.get("activity_at_ms") is not None else 0,
            thread_activity_time_ms(row),
            str(row["id"]),
        ),
        reverse=True,
    )
    if limit is not None:
        return rows[:limit]
    return rows


def should_update_rollout_meta(meta: RolloutMeta, current_provider: str, current_model: str | None) -> bool:
    if meta.model_provider != current_provider:
        return True
    if current_model and meta.model != current_model:
        return True
    return False


def collect_rollout_metas(paths: Paths) -> list[RolloutMeta]:
    metas = []
    for path in iter_rollout_paths(paths):
        meta = read_rollout_meta(path)
        if meta is not None:
            metas.append(meta)
    return metas


def collect_rollout_updates(
    paths: Paths,
    *,
    thread_ids: set[str],
    current_provider: str,
    current_model: str | None,
) -> list[RolloutMeta]:
    updates = []
    for meta in collect_rollout_metas(paths):
        if meta.thread_id in thread_ids and (
            should_update_rollout_meta(meta, current_provider, current_model)
            or rollout_has_outdated_turn_context(meta.path, current_model)
        ):
            updates.append(meta)
    return updates


def rollout_has_outdated_turn_context(path: Path, current_model: str | None) -> bool:
    if not current_model:
        return False
    with path.open("r", encoding="utf-8-sig") as handle:
        for line in handle:
            if '"turn_context"' not in line:
                continue
            stripped = line.strip()
            if not stripped:
                continue
            try:
                record = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if record.get("type") != "turn_context":
                continue
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue
            if payload.get("model") not in (None, current_model):
                return True
            collaboration_mode = payload.get("collaboration_mode")
            if not isinstance(collaboration_mode, dict):
                continue
            settings = collaboration_mode.get("settings")
            if isinstance(settings, dict) and settings.get("model") not in (None, current_model):
                return True
    return False


def newline_for_line(line: str) -> str:
    if line.endswith("\r\n"):
        return "\r\n"
    if line.endswith("\n"):
        return "\n"
    return ""


def rewrite_rollout_meta(path: Path, current_provider: str, current_model: str | None) -> bool:
    text = read_jsonl_text(path)
    lines = text.splitlines(keepends=True)
    changed = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            record = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if update_rollout_record(record, current_provider, current_model):
            lines[index] = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + newline_for_line(line)
            changed = True
    if not changed:
        return False
    path.write_text("".join(lines), encoding="utf-8")
    return True


def update_rollout_record(record: object, current_provider: str, current_model: str | None) -> bool:
    payload = extract_payload(record)
    if payload is not None:
        return update_session_meta_payload(payload, current_provider, current_model)
    if not isinstance(record, dict) or record.get("type") != "turn_context":
        return False
    turn_payload = record.get("payload")
    if not isinstance(turn_payload, dict):
        return False
    return update_turn_context_payload(turn_payload, current_model)


def update_session_meta_payload(
    payload: dict[str, object],
    current_provider: str,
    current_model: str | None,
) -> bool:
    changed = False
    if payload.get("model_provider") != current_provider:
        payload["model_provider"] = current_provider
        changed = True
    if current_model and payload.get("model") != current_model:
        payload["model"] = current_model
        changed = True
    return changed


def update_turn_context_payload(payload: dict[str, object], current_model: str | None) -> bool:
    if not current_model:
        return False
    changed = False
    if payload.get("model") not in (None, current_model):
        payload["model"] = current_model
        changed = True
    collaboration_mode = payload.get("collaboration_mode")
    if isinstance(collaboration_mode, dict):
        settings = collaboration_mode.get("settings")
        if isinstance(settings, dict) and settings.get("model") not in (None, current_model):
            settings["model"] = current_model
            changed = True
    return changed


def read_jsonl_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8-sig")


def query_provider_counts(conn: sqlite3.Connection) -> OrderedDict[str, int]:
    counts = OrderedDict()
    for provider, count in conn.execute(
        """
        SELECT model_provider, COUNT(*)
        FROM threads
        GROUP BY model_provider
        ORDER BY COUNT(*) DESC, model_provider ASC
        """
    ):
        counts[provider or "(empty)"] = count
    return counts


def query_model_counts(conn: sqlite3.Connection) -> OrderedDict[str, int]:
    counts = OrderedDict()
    for model, count in conn.execute(
        """
        SELECT model, COUNT(*)
        FROM threads
        GROUP BY model
        ORDER BY COUNT(*) DESC, model ASC
        """
    ):
        counts[model or "(empty)"] = count
    return counts


def query_provider_model_counts(conn: sqlite3.Connection) -> list[dict[str, object]]:
    rows = []
    for provider, model, count in conn.execute(
        """
        SELECT model_provider, model, COUNT(*)
        FROM threads
        GROUP BY model_provider, model
        ORDER BY COUNT(*) DESC, model_provider ASC, model ASC
        """
    ):
        rows.append({"provider": provider or "(empty)", "model": model or "(empty)", "count": count})
    return rows


def query_cwd_counts(conn: sqlite3.Connection, limit: int = 20) -> list[dict[str, object]]:
    rows = []
    for cwd, count in conn.execute(
        """
        SELECT cwd, COUNT(*)
        FROM threads
        GROUP BY cwd
        ORDER BY COUNT(*) DESC, cwd ASC
        LIMIT ?
        """,
        (limit,),
    ):
        rows.append({"cwd": cwd or "(empty)", "count": count})
    return rows


def count_mismatched(conn: sqlite3.Connection, column: str, expected: str | None) -> int:
    if not expected:
        return 0
    return int(
        conn.execute(
            f"SELECT COUNT(*) FROM threads WHERE {column} IS NULL OR {column} <> ?",
            (expected,),
        ).fetchone()[0]
    )


def count_sync_candidates(
    conn: sqlite3.Connection,
    *,
    current_provider: str,
    current_model: str | None,
    columns: set[str],
) -> int:
    where_sql, params = build_sync_candidate_condition(current_provider, current_model, columns)
    return int(conn.execute(f"SELECT COUNT(*) FROM threads WHERE {where_sql}", params).fetchone()[0])


def count_threads(conn: sqlite3.Connection) -> int:
    return int(conn.execute("SELECT COUNT(*) FROM threads").fetchone()[0])


def get_sync_candidates(
    paths: Paths,
    limit: int = DEFAULT_CANDIDATE_LIST_LIMIT,
    include_current: bool = False,
) -> dict[str, object]:
    ensure_environment(paths)
    config_text = read_text(paths.config_path)
    current_provider = parse_current_provider(config_text)
    current_model = parse_current_model(config_text)

    with connect_db(paths.db_path, readonly=True) as conn:
        columns = get_thread_columns(conn)
        total_candidates = count_sync_candidates(
            conn,
            current_provider=current_provider,
            current_model=current_model,
            columns=columns,
        )
        total_threads = count_threads(conn)
        candidates = query_sync_candidates(
            conn,
            paths=paths,
            current_provider=current_provider,
            current_model=current_model,
            columns=columns,
            limit=limit,
            include_current=include_current,
        )

    default_selected = [
        row["id"]
        for row in candidates
        if row.get("can_sync")
    ][:DEFAULT_SELECTED_CANDIDATES]
    return {
        "action": "list-candidates",
        "current_provider": current_provider,
        "current_model": current_model,
        "include_current": include_current,
        "total_threads": total_threads,
        "total_candidates": total_candidates,
        "current_count": total_threads - total_candidates,
        "total_displayed": len(candidates),
        "default_selected_count": len(default_selected),
        "default_selected_thread_ids": default_selected,
        "limit": limit,
        "candidates": candidates,
    }


def get_latest_candidate_thread_ids(paths: Paths, limit: int) -> list[str]:
    if limit <= 0:
        return []
    candidates = get_sync_candidates(paths, limit=limit)
    return [str(row["id"]) for row in candidates["candidates"]]


def is_snapshot_backup(path: Path) -> bool:
    return path.is_dir() and (path / "manifest.json").exists()


def is_legacy_sqlite_backup(path: Path) -> bool:
    return path.is_file() and path.name.startswith("state_5.sqlite.") and path.name.endswith(".bak")


def list_backups(paths: Paths, limit: int = 20) -> list[dict[str, str]]:
    if not paths.backup_dir.exists():
        return []
    items = [item for item in paths.backup_dir.iterdir() if is_legacy_sqlite_backup(item) or is_snapshot_backup(item)]
    files = sorted(
        items,
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    output = []
    for item in files[:limit]:
        output.append(
            {
                "name": item.name,
                "path": str(item),
                "type": "snapshot" if is_snapshot_backup(item) else "sqlite",
                "modified_at": datetime.fromtimestamp(item.stat().st_mtime).isoformat(timespec="seconds"),
            }
        )
    return output


def build_rollout_status(paths: Paths, thread_rows: dict[str, dict[str, str | None]]) -> dict[str, object]:
    provider_counts: Counter[str] = Counter()
    model_counts: Counter[str] = Counter()
    rollout_thread_ids: set[str] = set()
    mismatch_count = 0

    for meta in collect_rollout_metas(paths):
        provider_counts[meta.model_provider or "(empty)"] += 1
        model_counts[meta.model or "(empty)"] += 1
        rollout_thread_ids.add(meta.thread_id)
        thread = thread_rows.get(meta.thread_id)
        if not thread:
            continue
        if thread.get("model_provider") != meta.model_provider:
            mismatch_count += 1
            continue
        db_model = thread.get("model")
        if db_model is not None and meta.model is not None and db_model != meta.model:
            mismatch_count += 1

    return {
        "rollout_total": sum(provider_counts.values()),
        "rollout_provider_counts": [
            {"provider": key, "count": value}
            for key, value in sorted(provider_counts.items(), key=lambda item: (-item[1], item[0]))
        ],
        "rollout_model_counts": [
            {"model": key, "count": value}
            for key, value in sorted(model_counts.items(), key=lambda item: (-item[1], item[0]))
        ],
        "rollout_db_mismatch_threads": mismatch_count,
        "threads_without_rollout": len(set(thread_rows) - rollout_thread_ids),
    }


def get_status(paths: Paths) -> dict[str, object]:
    ensure_environment(paths)
    config_text = read_text(paths.config_path)
    current_provider = parse_current_provider(config_text)
    current_model = parse_current_model(config_text)

    with connect_db(paths.db_path, readonly=True) as conn:
        columns = get_thread_columns(conn)
        counts = query_provider_counts(conn)
        model_counts = query_model_counts(conn) if "model" in columns else OrderedDict()
        provider_model_counts = query_provider_model_counts(conn) if "model" in columns else []
        cwd_counts = query_cwd_counts(conn) if "cwd" in columns else []
        thread_rows = query_thread_metadata(conn)
        total_threads = conn.execute("SELECT COUNT(*) FROM threads").fetchone()[0]
        provider_movable = count_mismatched(conn, "model_provider", current_provider)
        model_movable = count_mismatched(conn, "model", current_model) if "model" in columns else None
        moved_if_sync = count_sync_candidates(
            conn,
            current_provider=current_provider,
            current_model=current_model,
            columns=columns,
        )
    rollout_status = build_rollout_status(paths, thread_rows)

    status = {
        "codex_home": str(paths.codex_home),
        "config_path": str(paths.config_path),
        "db_path": str(paths.db_path),
        "backup_dir": str(paths.backup_dir),
        "sessions_dir": str(paths.sessions_dir),
        "archived_sessions_dir": str(paths.archived_sessions_dir),
        "current_provider": current_provider,
        "current_model": current_model,
        "total_threads": total_threads,
        "movable_threads": moved_if_sync,
        "provider_movable_threads": provider_movable,
        "model_movable_threads": model_movable,
        "provider_counts": [{"provider": key, "count": value} for key, value in counts.items()],
        "model_counts": [{"model": key, "count": value} for key, value in model_counts.items()],
        "provider_model_counts": provider_model_counts,
        "cwd_counts": cwd_counts,
        "backups": list_backups(paths),
    }
    status.update(rollout_status)
    return status


def safe_backup_name(index: int, path: Path) -> str:
    digest = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:16]
    return f"{index:06d}-{digest}.jsonl"


def unique_snapshot_path(paths: Paths, label: str) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base_path = paths.backup_dir / f"snapshot.{label}.{timestamp}"
    if not base_path.exists():
        return base_path
    for index in range(1, 1000):
        candidate = paths.backup_dir / f"snapshot.{label}.{timestamp}.{index:03d}"
        if not candidate.exists():
            return candidate
    raise RuntimeError("Could not allocate a unique backup snapshot path.")


def relative_to_codex_home(paths: Paths, path: Path) -> str:
    try:
        return str(path.resolve().relative_to(paths.codex_home.resolve()))
    except ValueError as exc:
        raise RuntimeError(f"Refusing to backup rollout outside Codex home: {path}") from exc


def make_backup(
    paths: Paths,
    label: str,
    rollout_paths: Iterable[Path] | None = None,
    *,
    full_rollout: bool = False,
) -> Path:
    paths.backup_dir.mkdir(parents=True, exist_ok=True)
    backup_path = unique_snapshot_path(paths, label)
    backup_path.mkdir()
    db_backup_path = backup_path / "state_5.sqlite.bak"
    with connect_db(paths.db_path, readonly=True) as source, connect_db(db_backup_path, readonly=False) as target:
        source.backup(target)

    if full_rollout:
        rollout_items = list(iter_rollout_paths(paths))
    else:
        rollout_items = list(rollout_paths or [])

    rollout_dir = backup_path / "rollouts"
    rollout_entries = []
    for index, rollout_path in enumerate(sorted(set(rollout_items), key=lambda item: str(item)), start=1):
        if not rollout_path.exists():
            continue
        rollout_dir.mkdir(exist_ok=True)
        backup_name = safe_backup_name(index, rollout_path)
        backup_file = rollout_dir / backup_name
        shutil.copy2(rollout_path, backup_file)
        meta = read_rollout_meta(rollout_path)
        rollout_entries.append(
            {
                "path": str(rollout_path),
                "relative_path": relative_to_codex_home(paths, rollout_path),
                "backup_path": str(Path("rollouts") / backup_name),
                "thread_id": meta.thread_id if meta else None,
                "model_provider": meta.model_provider if meta else None,
                "model": meta.model if meta else None,
            }
        )

    manifest = {
        "version": SNAPSHOT_VERSION,
        "label": label,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "codex_home": str(paths.codex_home),
        "db_backup": "state_5.sqlite.bak",
        "rollout_files": rollout_entries,
    }
    (backup_path / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return backup_path


def checkpoint(conn: sqlite3.Connection) -> tuple[int, int, int]:
    row = conn.execute("PRAGMA wal_checkpoint(FULL)").fetchone()
    return int(row[0]), int(row[1]), int(row[2])


def sync_to_current_provider(paths: Paths, thread_ids: Iterable[str] | None = None) -> dict[str, object]:
    status_before = get_status(paths)
    current_provider = str(status_before["current_provider"])
    current_model = status_before.get("current_model")
    current_model = str(current_model) if current_model else None
    selected_ids = normalized_thread_ids(thread_ids)

    with connect_db(paths.db_path, readonly=True) as conn:
        columns = get_thread_columns(conn)
        if thread_ids is not None and not selected_ids:
            candidate_thread_ids: set[str] = set()
        else:
            candidate_thread_ids = query_sync_candidate_thread_ids(
                conn,
                current_provider=current_provider,
                current_model=current_model,
                columns=columns,
                thread_ids=selected_ids if thread_ids is not None else None,
            )

    rollout_scope_thread_ids = set(selected_ids) if thread_ids is not None else candidate_thread_ids
    rollout_updates = collect_rollout_updates(
        paths,
        thread_ids=rollout_scope_thread_ids,
        current_provider=current_provider,
        current_model=current_model,
    )
    backup_path = (
        make_backup(paths, "pre-sync", (meta.path for meta in rollout_updates))
        if candidate_thread_ids or rollout_updates
        else None
    )

    with connect_db(paths.db_path, readonly=False) as conn:
        columns = get_thread_columns(conn)
        before_counts = query_provider_counts(conn)
        before_model_counts = query_model_counts(conn) if "model" in columns else OrderedDict()

        set_parts = ["model_provider = ?"]
        set_params = [current_provider]
        where_parts = ["model_provider IS NULL OR model_provider <> ?"]
        where_params = [current_provider]
        synced_fields = ["model_provider"]

        if "model" in columns and current_model:
            set_parts.append("model = ?")
            set_params.append(current_model)
            where_parts.append("model IS NULL OR model <> ?")
            where_params.append(current_model)
            synced_fields.append("model")

        if candidate_thread_ids:
            set_sql = ", ".join(set_parts)
            where_sql = " OR ".join(f"({part})" for part in where_parts)
            if thread_ids is not None:
                where_sql, where_params = add_thread_id_filter(where_sql, where_params, sorted(candidate_thread_ids))
            updated_rows = conn.execute(
                f"UPDATE threads SET {set_sql} WHERE {where_sql}",
                (*set_params, *where_params),
            ).rowcount
            conn.commit()
            checkpoint_result = checkpoint(conn)
        else:
            updated_rows = 0
            checkpoint_result = (0, 0, 0)
        after_counts = query_provider_counts(conn)
        after_model_counts = query_model_counts(conn) if "model" in columns else OrderedDict()

    updated_rollout_files = 0
    for meta in rollout_updates:
        if rewrite_rollout_meta(meta.path, current_provider, current_model):
            updated_rollout_files += 1

    return {
        "action": "sync",
        "current_provider": current_provider,
        "current_model": current_model,
        "synced_fields": synced_fields,
        "updated_rows": updated_rows,
        "updated_rollout_files": updated_rollout_files,
        "rollout_candidate_files": len(rollout_updates),
        "requested_thread_ids": selected_ids if thread_ids is not None else None,
        "selected_thread_ids": sorted(candidate_thread_ids),
        "provider_movable_threads": status_before["provider_movable_threads"],
        "model_movable_threads": status_before["model_movable_threads"],
        "backup_path": str(backup_path) if backup_path else None,
        "before_counts": [{"provider": key, "count": value} for key, value in before_counts.items()],
        "after_counts": [{"provider": key, "count": value} for key, value in after_counts.items()],
        "before_model_counts": [{"model": key, "count": value} for key, value in before_model_counts.items()],
        "after_model_counts": [{"model": key, "count": value} for key, value in after_model_counts.items()],
        "checkpoint": {
            "busy": checkpoint_result[0],
            "log_frames": checkpoint_result[1],
            "checkpointed_frames": checkpoint_result[2],
        },
    }


def resolve_backup(paths: Paths, requested_path: str | None) -> Path:
    if requested_path:
        backup = Path(requested_path).expanduser()
    else:
        backups = list_backups(paths, limit=1)
        if not backups:
            raise RuntimeError("No backup files were found.")
        backup = Path(backups[0]["path"])
    if not backup.exists():
        raise RuntimeError(f"Backup file does not exist: {backup}")
    return backup


def read_snapshot_manifest(snapshot_path: Path) -> dict[str, object]:
    manifest_path = snapshot_path / "manifest.json"
    if not manifest_path.exists():
        raise RuntimeError(f"Missing snapshot manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise RuntimeError(f"Invalid snapshot manifest: {manifest_path}")
    if manifest.get("version") != SNAPSHOT_VERSION:
        raise RuntimeError(f"Unsupported snapshot version: {manifest.get('version')}")
    return manifest


def manifest_rollout_paths(paths: Paths, manifest: dict[str, object]) -> list[Path]:
    rollout_files = manifest.get("rollout_files")
    if not isinstance(rollout_files, list):
        return []
    output = []
    for entry in rollout_files:
        if not isinstance(entry, dict):
            continue
        relative_path = entry.get("relative_path")
        if not isinstance(relative_path, str) or not relative_path:
            continue
        output.append(paths.codex_home / relative_path)
    return output


def resolve_snapshot_file(snapshot_path: Path, relative_path: str) -> Path:
    source = snapshot_path / relative_path
    try:
        source.resolve().relative_to(snapshot_path.resolve())
    except ValueError as exc:
        raise RuntimeError(f"Snapshot file escapes backup directory: {relative_path}") from exc
    if not source.exists():
        raise RuntimeError(f"Missing snapshot file: {source}")
    return source


def restore_snapshot_rollouts(paths: Paths, snapshot_path: Path, manifest: dict[str, object]) -> int:
    rollout_files = manifest.get("rollout_files")
    if not isinstance(rollout_files, list):
        return 0

    restored = 0
    for entry in rollout_files:
        if not isinstance(entry, dict):
            continue
        backup_relative = entry.get("backup_path")
        target_relative = entry.get("relative_path")
        if not isinstance(backup_relative, str) or not isinstance(target_relative, str):
            continue
        source = resolve_snapshot_file(snapshot_path, backup_relative)
        target = paths.codex_home / target_relative
        try:
            target.resolve().relative_to(paths.codex_home.resolve())
        except ValueError as exc:
            raise RuntimeError(f"Refusing to restore rollout outside Codex home: {target}") from exc
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        restored += 1
    return restored


def restore_backup(paths: Paths, backup_path: str | None) -> dict[str, object]:
    ensure_environment(paths)
    chosen_backup = resolve_backup(paths, backup_path)
    manifest = read_snapshot_manifest(chosen_backup) if is_snapshot_backup(chosen_backup) else None
    restore_rollout_paths = manifest_rollout_paths(paths, manifest) if manifest else []
    restore_snapshot = make_backup(paths, "pre-restore", restore_rollout_paths)

    db_backup = manifest.get("db_backup", "state_5.sqlite.bak") if manifest else None
    if manifest and not isinstance(db_backup, str):
        raise RuntimeError("Invalid snapshot manifest db_backup.")
    db_source_path = (
        resolve_snapshot_file(chosen_backup, db_backup)
        if manifest
        else chosen_backup
    )
    with connect_db(db_source_path, readonly=True) as source, connect_db(paths.db_path, readonly=False) as target:
        source.backup(target)
        checkpoint_result = checkpoint(target)

    restored_rollout_files = restore_snapshot_rollouts(paths, chosen_backup, manifest) if manifest else 0

    status_after = get_status(paths)
    return {
        "action": "restore",
        "restored_from": str(chosen_backup),
        "safety_backup": str(restore_snapshot),
        "restored_rollout_files": restored_rollout_files,
        "checkpoint": {
            "busy": checkpoint_result[0],
            "log_frames": checkpoint_result[1],
            "checkpointed_frames": checkpoint_result[2],
        },
        "status": status_after,
    }


def to_json(payload: dict[str, object]) -> str:
    return json.dumps(payload, ensure_ascii=True, indent=2)


def main() -> int:
    parser = argparse.ArgumentParser(description="Codex history sync helper")
    parser.add_argument("--codex-home", help="Override Codex home directory")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status", help="Show current provider/thread status")
    candidates_parser = subparsers.add_parser("list-candidates", help="List threads that can be moved to current settings")
    candidates_parser.add_argument("--limit", type=int, default=DEFAULT_CANDIDATE_LIST_LIMIT)
    candidates_parser.add_argument("--include-current", action="store_true", help="Include current provider/model threads as read-only rows")
    sync_parser = subparsers.add_parser("sync", help="Move selected thread providers/models to the current settings")
    sync_parser.add_argument("--thread-id", action="append", help="Thread id to sync; repeat for multiple threads")
    sync_parser.add_argument("--latest", type=int, help="Sync the newest N candidate threads")
    restore_parser = subparsers.add_parser("restore", help="Restore from a backup")
    restore_parser.add_argument("--backup", help="Backup file path; newest backup is used when omitted")
    subparsers.add_parser("backup", help="Create a manual backup")

    args = parser.parse_args()
    paths = resolve_paths(args.codex_home)

    try:
        if args.command == "status":
            payload = get_status(paths)
        elif args.command == "list-candidates":
            payload = get_sync_candidates(paths, limit=args.limit, include_current=args.include_current)
        elif args.command == "sync":
            if args.thread_id:
                payload = sync_to_current_provider(paths, args.thread_id)
            elif args.latest is not None:
                payload = sync_to_current_provider(paths, get_latest_candidate_thread_ids(paths, args.latest))
            else:
                payload = sync_to_current_provider(paths)
        elif args.command == "restore":
            payload = restore_backup(paths, args.backup)
        elif args.command == "backup":
            ensure_environment(paths)
            payload = {"action": "backup", "backup_path": str(make_backup(paths, "manual", full_rollout=True))}
        else:
            raise RuntimeError(f"Unsupported command: {args.command}")
    except Exception as exc:
        error_payload = {"ok": False, "error": str(exc)}
        if args.json:
            print(to_json(error_payload))
        else:
            print(error_payload["error"])
        return 1

    if isinstance(payload, dict):
        payload["ok"] = True

    if args.json:
        print(to_json(payload))
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
