from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any, Optional

from .paths import DB_PATH, ensure_dirs

_lock = threading.Lock()
_conn: Optional[sqlite3.Connection] = None


def utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def connect() -> sqlite3.Connection:
    global _conn
    ensure_dirs()
    if _conn is None:
        _conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA foreign_keys = ON")
        _conn.execute("PRAGMA journal_mode = WAL")
        init_schema(_conn)
        DB_PATH.chmod(0o600)
    return _conn


def _cols(conn: sqlite3.Connection, table: str) -> set[str]:
    return {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def _add_col(conn: sqlite3.Connection, table: str, col: str, spec: str) -> None:
    if col not in _cols(conn, table):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {spec}")


def init_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS matters (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            case_no TEXT DEFAULT '',
            petitioner TEXT DEFAULT '',
            respondent TEXT DEFAULT '',
            style TEXT DEFAULT '',
            court TEXT DEFAULT 'Circuit Court',
            county TEXT DEFAULT '',
            division TEXT DEFAULT 'Family',
            status TEXT DEFAULT 'open',
            opposing_counsel TEXT DEFAULT '',
            rate REAL DEFAULT 0,
            notes TEXT DEFAULT '',
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            imap_uid TEXT,
            folder TEXT DEFAULT 'INBOX',
            message_id TEXT,
            in_reply_to TEXT DEFAULT '',
            from_addr TEXT DEFAULT '',
            to_addr TEXT DEFAULT '',
            cc_addr TEXT DEFAULT '',
            subject TEXT DEFAULT '',
            sent_at TEXT,
            snippet TEXT DEFAULT '',
            body_text TEXT DEFAULT '',
            body_html TEXT DEFAULT '',
            flags TEXT DEFAULT '[]',
            matter_id INTEGER,
            has_attachments INTEGER DEFAULT 0,
            synced_at TEXT
        );

        CREATE TABLE IF NOT EXISTS attachments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER NOT NULL,
            filename TEXT NOT NULL,
            mime TEXT DEFAULT '',
            size INTEGER DEFAULT 0,
            content BLOB,
            saved_path TEXT DEFAULT '',
            FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS time_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            matter_id INTEGER,
            message_id INTEGER,
            started_at TEXT,
            ended_at TEXT,
            minutes REAL DEFAULT 0,
            description TEXT DEFAULT '',
            activity TEXT DEFAULT 'email',
            billed INTEGER DEFAULT 0,
            rate REAL DEFAULT 0,
            running INTEGER DEFAULT 0,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            matter_id INTEGER,
            title TEXT DEFAULT '',
            body TEXT DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            matter_id INTEGER,
            message_id INTEGER,
            title TEXT NOT NULL,
            event_type TEXT DEFAULT 'appointment',
            start_at TEXT NOT NULL,
            end_at TEXT,
            all_day INTEGER DEFAULT 1,
            location TEXT DEFAULT '',
            rule_cite TEXT DEFAULT '',
            source TEXT DEFAULT 'manual',
            notes TEXT DEFAULT '',
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            matter_id INTEGER,
            message_id INTEGER,
            filename TEXT NOT NULL,
            path TEXT NOT NULL,
            source TEXT DEFAULT 'upload',
            source_url TEXT DEFAULT '',
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS folders (
            name TEXT PRIMARY KEY,
            role TEXT DEFAULT '',
            delimiter TEXT DEFAULT '/',
            attrs TEXT DEFAULT '',
            last_uid INTEGER DEFAULT 0,
            unseen INTEGER DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT DEFAULT '',
            email TEXT NOT NULL UNIQUE,
            phone TEXT DEFAULT '',
            firm TEXT DEFAULT '',
            notes TEXT DEFAULT '',
            matter_id INTEGER,
            created_at TEXT NOT NULL
        );
        """
    )
    for col, spec in (
        ("bcc_addr", "TEXT DEFAULT ''"),
        ("references_header", "TEXT DEFAULT ''"),
        ("reply_to", "TEXT DEFAULT ''"),
        ("seen", "INTEGER DEFAULT 0"),
        ("flagged", "INTEGER DEFAULT 0"),
        ("deleted", "INTEGER DEFAULT 0"),
        ("draft", "INTEGER DEFAULT 0"),
        ("answered", "INTEGER DEFAULT 0"),
    ):
        _add_col(conn, "messages", col, spec)
    _add_col(conn, "events", "remind_minutes", "INTEGER DEFAULT 30")
    _add_col(conn, "events", "dismissed", "INTEGER DEFAULT 0")
    _add_col(conn, "matters", "client_email", "TEXT DEFAULT ''")
    _add_col(conn, "matters", "client_name", "TEXT DEFAULT ''")
    _add_col(conn, "files", "doc_type", "TEXT DEFAULT 'correspondence'")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_folder_mid ON messages(folder, message_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_folder_sent ON messages(folder, sent_at DESC)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_seen ON messages(seen, deleted)")
    conn.execute(
        """CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(
            subject, from_addr, to_addr, body_text
        )"""
    )
    for name, role in (("INBOX", "inbox"), ("SENT", "sent"), ("DRAFTS", "drafts")):
        conn.execute("INSERT OR IGNORE INTO folders(name, role, last_uid, unseen) VALUES (?, ?, 0, 0)", (name, role))
    conn.commit()
    n = conn.execute("SELECT COUNT(*) FROM matters").fetchone()[0]
    if n == 0:
        conn.execute(
            """INSERT INTO matters (case_no, petitioner, respondent, style, county, division, status, notes, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "INTAKE",
                "",
                "",
                "Intake / unassigned mail",
                "",
                "Family",
                "open",
                "Park mail here until it is attached to a matter.",
                utcnow(),
            ),
        )
        conn.commit()


def rows(sql: str, params: tuple = ()) -> list[dict[str, Any]]:
    with _lock:
        cur = connect().execute(sql, params)
        return [dict(r) for r in cur.fetchall()]


def one(sql: str, params: tuple = ()) -> Optional[dict[str, Any]]:
    found = rows(sql, params)
    return found[0] if found else None


def execute(sql: str, params: tuple = ()) -> int:
    with _lock:
        conn = connect()
        cur = conn.execute(sql, params)
        conn.commit()
        return int(cur.lastrowid)


def executemany(sql: str, seq: list[tuple]) -> None:
    with _lock:
        conn = connect()
        conn.executemany(sql, seq)
        conn.commit()


def setting(key: str, default: str = "") -> str:
    row = one("SELECT value FROM settings WHERE key = ?", (key,))
    return row["value"] if row else default


def set_setting(key: str, value: str) -> None:
    execute(
        "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )


def get_settings() -> dict[str, str]:
    data = {r["key"]: r["value"] for r in rows("SELECT key, value FROM settings")}
    if "imap_password" in data:
        data["imap_password_set"] = "1" if data.get("imap_password") else "0"
        data["imap_password"] = "••••••" if data.get("imap_password") else ""
    if "smtp_password" in data:
        data["smtp_password_set"] = "1" if data.get("smtp_password") else "0"
        data["smtp_password"] = "••••••" if data.get("smtp_password") else ""
    return data


def save_settings(payload: dict[str, Any]) -> dict[str, str]:
    secrets = {"imap_password", "smtp_password"}
    for key, value in payload.items():
        if not isinstance(key, str):
            continue
        if key in secrets and (value in (None, "", "••••••")):
            continue
        if isinstance(value, bool):
            value = "1" if value else "0"
        set_setting(key, "" if value is None else str(value))
    return get_settings()


def json_list(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value or [])


def fts_upsert(msg_id: int) -> None:
    row = one("SELECT id, subject, from_addr, to_addr, body_text FROM messages WHERE id = ?", (msg_id,))
    if not row:
        return
    execute("DELETE FROM mail_fts WHERE rowid = ?", (msg_id,))
    execute(
        "INSERT INTO mail_fts(rowid, subject, from_addr, to_addr, body_text) VALUES (?, ?, ?, ?, ?)",
        (row["id"], row["subject"] or "", row["from_addr"] or "", row["to_addr"] or "", row["body_text"] or ""),
    )


def search_mail(query: str, folder: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
    q = (query or "").strip()
    if not q:
        if folder and folder != "ALL":
            return rows(
                """SELECT id, folder, from_addr, to_addr, subject, sent_at, snippet, matter_id,
                          has_attachments, seen, flagged, deleted, draft
                   FROM messages WHERE deleted = 0 AND folder = ?
                   ORDER BY sent_at DESC, id DESC LIMIT ?""",
                (folder, limit),
            )
        return rows(
            """SELECT id, folder, from_addr, to_addr, subject, sent_at, snippet, matter_id,
                      has_attachments, seen, flagged, deleted, draft
               FROM messages WHERE deleted = 0
               ORDER BY sent_at DESC, id DESC LIMIT ?""",
            (limit,),
        )
    try:
        ids = [r["rowid"] for r in rows("SELECT rowid FROM mail_fts WHERE mail_fts MATCH ? LIMIT ?", (q, limit))]
    except sqlite3.OperationalError:
        ids = []
    if not ids:
        like = f"%{q}%"
        sql = """SELECT id, folder, from_addr, to_addr, subject, sent_at, snippet, matter_id,
                        has_attachments, seen, flagged, deleted, draft
                 FROM messages WHERE deleted = 0 AND
                 (subject LIKE ? OR from_addr LIKE ? OR to_addr LIKE ? OR snippet LIKE ? OR body_text LIKE ?)"""
        params: tuple = (like, like, like, like, like)
        if folder and folder != "ALL":
            sql += " AND folder = ?"
            params += (folder,)
        sql += " ORDER BY sent_at DESC, id DESC LIMIT ?"
        params += (limit,)
        return rows(sql, params)
    placeholders = ",".join("?" * len(ids))
    sql = f"""SELECT id, folder, from_addr, to_addr, subject, sent_at, snippet, matter_id,
                     has_attachments, seen, flagged, deleted, draft
              FROM messages WHERE deleted = 0 AND id IN ({placeholders})"""
    params = tuple(ids)
    if folder and folder != "ALL":
        sql += " AND folder = ?"
        params += (folder,)
    sql += " ORDER BY sent_at DESC, id DESC"
    return rows(sql, params)
