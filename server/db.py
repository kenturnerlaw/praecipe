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

        CREATE TABLE IF NOT EXISTS signatures (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            body TEXT DEFAULT '',
            is_default INTEGER DEFAULT 0,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT DEFAULT 'imap',
            email TEXT NOT NULL,
            display_name TEXT DEFAULT '',
            description TEXT DEFAULT '',
            imap_host TEXT DEFAULT '',
            imap_port TEXT DEFAULT '993',
            imap_user TEXT DEFAULT '',
            imap_password TEXT DEFAULT '',
            smtp_host TEXT DEFAULT '',
            smtp_port TEXT DEFAULT '587',
            smtp_user TEXT DEFAULT '',
            smtp_password TEXT DEFAULT '',
            smtp_tls TEXT DEFAULT 'starttls',
            auth_type TEXT DEFAULT 'password',
            oauth_refresh_token TEXT DEFAULT '',
            oauth_access_token TEXT DEFAULT '',
            oauth_expires_at INTEGER DEFAULT 0,
            is_default INTEGER DEFAULT 0,
            enabled INTEGER DEFAULT 1,
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
    _add_col(conn, "messages", "labels", "TEXT DEFAULT '[]'")
    _add_col(conn, "messages", "account_id", "INTEGER DEFAULT 1")
    _migrate_folders(conn)
    conn.execute("DROP INDEX IF EXISTS idx_messages_folder_mid")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_acct_folder_mid ON messages(account_id, folder, message_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_folder_sent ON messages(folder, sent_at DESC)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_seen ON messages(seen, deleted)")
    conn.execute(
        """CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(
            subject, from_addr, to_addr, body_text
        )"""
    )
    for name, role in (("INBOX", "inbox"), ("SENT", "sent"), ("DRAFTS", "drafts")):
        conn.execute(
            "INSERT OR IGNORE INTO folders(account_id, name, role, last_uid, unseen) VALUES (1, ?, ?, 0, 0)",
            (name, role),
        )
    conn.commit()
    seed_signatures(conn)
    seed_accounts(conn)
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


def seed_signatures(conn: sqlite3.Connection) -> None:
    n = conn.execute("SELECT COUNT(*) FROM signatures").fetchone()[0]
    if n:
        return
    old = conn.execute("SELECT value FROM settings WHERE key = 'signature'").fetchone()
    name_row = conn.execute("SELECT value FROM settings WHERE key = 'display_name'").fetchone()
    display = (name_row[0] if name_row else "") or "Kenneth Turner"
    body = (old[0] if old and old[0] else "").strip() or (
        f"{display}\n"
        "Attorney and Counselor at Law\n"
        "\n"
        "CONFIDENTIALITY NOTICE: This electronic message and any attachments are confidential "
        "and may be protected by the attorney-client privilege. If you are not the intended "
        "recipient, please notify the sender immediately, delete the message, and do not copy "
        "or disclose its contents."
    )
    conn.execute(
        "INSERT INTO signatures (name, body, is_default, created_at) VALUES (?, ?, 1, ?)",
        ("Standard", body, utcnow()),
    )
    conn.commit()


def _migrate_folders(conn: sqlite3.Connection) -> None:
    cols = _cols(conn, "folders")
    if "id" in cols and "account_id" in cols:
        return
    conn.execute("ALTER TABLE folders RENAME TO folders_old")
    conn.execute(
        """CREATE TABLE folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL DEFAULT 1,
            name TEXT NOT NULL,
            role TEXT DEFAULT '',
            delimiter TEXT DEFAULT '/',
            attrs TEXT DEFAULT '',
            last_uid INTEGER DEFAULT 0,
            unseen INTEGER DEFAULT 0,
            UNIQUE(account_id, name)
        )"""
    )
    old_cols = {r[1] for r in conn.execute("PRAGMA table_info(folders_old)").fetchall()}
    if "account_id" in old_cols:
        conn.execute(
            """INSERT INTO folders (account_id, name, role, delimiter, attrs, last_uid, unseen)
               SELECT account_id, name, role, delimiter, attrs, last_uid, unseen FROM folders_old"""
        )
    else:
        conn.execute(
            """INSERT INTO folders (account_id, name, role, delimiter, attrs, last_uid, unseen)
               SELECT 1, name, role, delimiter, attrs, last_uid, unseen FROM folders_old"""
        )
    conn.execute("DROP TABLE folders_old")
    conn.commit()


def seed_accounts(conn: sqlite3.Connection) -> None:
    n = conn.execute("SELECT COUNT(*) FROM accounts").fetchone()[0]
    if n:
        return
    get = lambda k: (conn.execute("SELECT value FROM settings WHERE key = ?", (k,)).fetchone() or [""])[0]
    host = get("imap_host")
    user = get("imap_user")
    if not host or not user:
        return
    conn.execute(
        """INSERT INTO accounts (provider, email, display_name, description, imap_host, imap_port, imap_user,
           imap_password, smtp_host, smtp_port, smtp_user, smtp_password, smtp_tls, auth_type, is_default, enabled, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'password', 1, 1, ?)""",
        (
            get("preset") or "imap",
            get("email_address") or user,
            get("display_name") or "",
            get("account_description") or "Praecipe",
            host,
            get("imap_port") or "993",
            user,
            get("imap_password") or "",
            get("smtp_host") or "",
            get("smtp_port") or "587",
            get("smtp_user") or user,
            get("smtp_password") or get("imap_password") or "",
            get("smtp_tls") or "starttls",
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
    for key in ("google_oauth_client_secret", "microsoft_oauth_client_secret"):
        if data.get(key):
            data[f"{key}_set"] = "1"
            data[key] = "••••••"
    data["google_oauth_ready"] = "1" if data.get("google_oauth_client_id") else "0"
    data["microsoft_oauth_ready"] = "1" if data.get("microsoft_oauth_client_id") else "0"
    return data


def save_settings(payload: dict[str, Any]) -> dict[str, str]:
    secrets = {
        "imap_password",
        "smtp_password",
        "google_oauth_client_secret",
        "microsoft_oauth_client_secret",
    }
    skip = {"preset", "sig_name", "sig_body"}
    for key, value in payload.items():
        if not isinstance(key, str) or key.startswith("_") or key in skip:
            continue
        if key in secrets and (value in (None, "", "••••••")):
            continue
        if isinstance(value, bool):
            value = "1" if value else "0"
        set_setting(key, "" if value is None else str(value))
    return get_settings()


def _public_account(row: dict[str, Any]) -> dict[str, Any]:
    out = dict(row)
    out["imap_password_set"] = "1" if out.get("imap_password") else "0"
    out["smtp_password_set"] = "1" if out.get("smtp_password") else "0"
    out["oauth_set"] = "1" if out.get("oauth_refresh_token") else "0"
    out["imap_password"] = ""
    out["smtp_password"] = ""
    out["oauth_refresh_token"] = ""
    out["oauth_access_token"] = ""
    return out


def list_accounts(include_secrets: bool = False) -> list[dict[str, Any]]:
    items = rows("SELECT * FROM accounts ORDER BY is_default DESC, id")
    return items if include_secrets else [_public_account(r) for r in items]


def get_account(aid: int, include_secrets: bool = True) -> Optional[dict[str, Any]]:
    row = one("SELECT * FROM accounts WHERE id = ?", (aid,))
    if not row:
        return None
    return row if include_secrets else _public_account(row)


def default_account() -> Optional[dict[str, Any]]:
    row = one("SELECT * FROM accounts WHERE enabled = 1 AND is_default = 1 ORDER BY id LIMIT 1")
    if row:
        return row
    return one("SELECT * FROM accounts WHERE enabled = 1 ORDER BY id LIMIT 1")


def enabled_accounts() -> list[dict[str, Any]]:
    return rows("SELECT * FROM accounts WHERE enabled = 1 ORDER BY is_default DESC, id")


def set_default_account(aid: int) -> Optional[dict[str, Any]]:
    if not get_account(aid):
        return None
    execute("UPDATE accounts SET is_default = 0")
    execute("UPDATE accounts SET is_default = 1 WHERE id = ?", (aid,))
    row = get_account(aid)
    if row:
        set_setting("email_address", row.get("email") or "")
        set_setting("display_name", row.get("display_name") or "")
        set_setting("imap_host", row.get("imap_host") or "")
        set_setting("imap_user", row.get("imap_user") or "")
    return _public_account(row) if row else None


def delete_account(aid: int) -> None:
    execute("DELETE FROM accounts WHERE id = ?", (aid,))
    remaining = default_account()
    if remaining:
        set_default_account(remaining["id"])


def upsert_account(payload: dict[str, Any]) -> dict[str, Any]:
    email = (payload.get("email") or "").strip()
    if not email:
        raise ValueError("Email address is required.")
    existing = None
    if payload.get("id"):
        existing = get_account(int(payload["id"]))
    if not existing:
        existing = one("SELECT * FROM accounts WHERE lower(email) = lower(?)", (email,))
    password = payload.get("password") or payload.get("imap_password") or ""
    smtp_password = payload.get("smtp_password") or password
    if password in ("••••••",):
        password = ""
    count = one("SELECT COUNT(*) AS n FROM accounts")
    make_default = bool(payload.get("is_default")) or not (count or {}).get("n")
    fields = {
        "provider": payload.get("provider") or "imap",
        "email": email,
        "display_name": payload.get("display_name") or "",
        "description": payload.get("description") or "",
        "imap_host": payload.get("imap_host") or "",
        "imap_port": str(payload.get("imap_port") or "993"),
        "imap_user": payload.get("imap_user") or email,
        "smtp_host": payload.get("smtp_host") or "",
        "smtp_port": str(payload.get("smtp_port") or "587"),
        "smtp_user": payload.get("smtp_user") or email,
        "smtp_tls": payload.get("smtp_tls") or "starttls",
        "auth_type": payload.get("auth_type") or "password",
        "enabled": 1 if payload.get("enabled", 1) else 0,
    }
    if existing:
        aid = existing["id"]
        sets = ", ".join(f"{k}=?" for k in fields)
        execute(f"UPDATE accounts SET {sets} WHERE id=?", tuple(fields.values()) + (aid,))
        if password:
            execute("UPDATE accounts SET imap_password=?, smtp_password=? WHERE id=?", (password, smtp_password or password, aid))
        if payload.get("oauth_refresh_token"):
            execute(
                "UPDATE accounts SET oauth_refresh_token=?, oauth_access_token=?, oauth_expires_at=?, auth_type=? WHERE id=?",
                (
                    payload.get("oauth_refresh_token") or "",
                    payload.get("oauth_access_token") or "",
                    int(payload.get("oauth_expires_at") or 0),
                    payload.get("auth_type") or "oauth",
                    aid,
                ),
            )
        if make_default:
            set_default_account(aid)
        return get_account(aid) or existing
    if make_default:
        execute("UPDATE accounts SET is_default = 0")
    aid = execute(
        """INSERT INTO accounts (provider, email, display_name, description, imap_host, imap_port, imap_user,
           imap_password, smtp_host, smtp_port, smtp_user, smtp_password, smtp_tls, auth_type,
           oauth_refresh_token, oauth_access_token, oauth_expires_at, is_default, enabled, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)""",
        (
            fields["provider"],
            fields["email"],
            fields["display_name"],
            fields["description"],
            fields["imap_host"],
            fields["imap_port"],
            fields["imap_user"],
            password,
            fields["smtp_host"],
            fields["smtp_port"],
            fields["smtp_user"],
            smtp_password,
            fields["smtp_tls"],
            fields["auth_type"],
            payload.get("oauth_refresh_token") or "",
            payload.get("oauth_access_token") or "",
            int(payload.get("oauth_expires_at") or 0),
            1 if make_default else 0,
            utcnow(),
        ),
    )
    if make_default:
        set_default_account(aid)
    return get_account(aid) or {}


def json_list(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value or [])


def default_signature() -> str:
    row = one("SELECT body FROM signatures WHERE is_default = 1 ORDER BY id LIMIT 1")
    if row:
        return row["body"] or ""
    row = one("SELECT body FROM signatures ORDER BY id LIMIT 1")
    return (row or {}).get("body") or setting("signature")


def list_signatures() -> list[dict[str, Any]]:
    return rows("SELECT * FROM signatures ORDER BY name COLLATE NOCASE, id")


def get_signature(sid: int) -> Optional[dict[str, Any]]:
    return one("SELECT * FROM signatures WHERE id = ?", (sid,))


def create_signature(name: str = "", body: str = "", is_default: bool = False) -> dict[str, Any]:
    existing = rows("SELECT name FROM signatures")
    names = {r["name"] for r in existing}
    label = (name or "Signature").strip() or "Signature"
    if label in names:
        n = 2
        while f"{label} {n}" in names:
            n += 1
        label = f"{label} {n}"
    if is_default or not existing:
        execute("UPDATE signatures SET is_default = 0")
        is_default = True
    sid = execute(
        "INSERT INTO signatures (name, body, is_default, created_at) VALUES (?, ?, ?, ?)",
        (label, body or "", 1 if is_default else 0, utcnow()),
    )
    return get_signature(sid) or {}


def update_signature(sid: int, name: str, body: str) -> Optional[dict[str, Any]]:
    execute("UPDATE signatures SET name = ?, body = ? WHERE id = ?", ((name or "Untitled").strip() or "Untitled", body or "", sid))
    return get_signature(sid)


def set_default_signature(sid: int) -> Optional[dict[str, Any]]:
    if not get_signature(sid):
        return None
    execute("UPDATE signatures SET is_default = 0")
    execute("UPDATE signatures SET is_default = 1 WHERE id = ?", (sid,))
    return get_signature(sid)


def delete_signature(sid: int) -> None:
    row = get_signature(sid)
    execute("DELETE FROM signatures WHERE id = ?", (sid,))
    if row and row.get("is_default"):
        first = one("SELECT id FROM signatures ORDER BY id LIMIT 1")
        if first:
            execute("UPDATE signatures SET is_default = 1 WHERE id = ?", (first["id"],))


def fts_upsert(msg_id: int) -> None:
    row = one("SELECT id, subject, from_addr, to_addr, body_text FROM messages WHERE id = ?", (msg_id,))
    if not row:
        return
    execute("DELETE FROM mail_fts WHERE rowid = ?", (msg_id,))
    execute(
        "INSERT INTO mail_fts(rowid, subject, from_addr, to_addr, body_text) VALUES (?, ?, ?, ?, ?)",
        (row["id"], row["subject"] or "", row["from_addr"] or "", row["to_addr"] or "", row["body_text"] or ""),
    )


def search_mail(query: str, folder: str | None = None, limit: int = 200, label: str | None = None) -> list[dict[str, Any]]:
    q = (query or "").strip()
    label_sql = ""
    label_params: tuple = ()
    if label:
        label_sql = " AND labels LIKE ?"
        label_params = (f'%"{label}"%',)
    cols = """id, folder, from_addr, to_addr, subject, sent_at, snippet, matter_id,
              has_attachments, seen, flagged, deleted, draft, labels"""
    if not q:
        if folder and folder != "ALL":
            return rows(
                f"""SELECT {cols}
                   FROM messages WHERE deleted = 0 AND folder = ?{label_sql}
                   ORDER BY sent_at DESC, id DESC LIMIT ?""",
                (folder,) + label_params + (limit,),
            )
        return rows(
            f"""SELECT {cols}
               FROM messages WHERE deleted = 0{label_sql}
               ORDER BY sent_at DESC, id DESC LIMIT ?""",
            label_params + (limit,),
        )
    try:
        ids = [r["rowid"] for r in rows("SELECT rowid FROM mail_fts WHERE mail_fts MATCH ? LIMIT ?", (q, limit))]
    except sqlite3.OperationalError:
        ids = []
    if not ids:
        like = f"%{q}%"
        sql = f"""SELECT {cols}
                 FROM messages WHERE deleted = 0 AND
                 (subject LIKE ? OR from_addr LIKE ? OR to_addr LIKE ? OR snippet LIKE ? OR body_text LIKE ?){label_sql}"""
        params: tuple = (like, like, like, like, like) + label_params
        if folder and folder != "ALL":
            sql += " AND folder = ?"
            params += (folder,)
        sql += " ORDER BY sent_at DESC, id DESC LIMIT ?"
        params += (limit,)
        return rows(sql, params)
    placeholders = ",".join("?" * len(ids))
    sql = f"""SELECT {cols}
              FROM messages WHERE deleted = 0 AND id IN ({placeholders}){label_sql}"""
    params = tuple(ids) + label_params
    if folder and folder != "ALL":
        sql += " AND folder = ?"
        params += (folder,)
    sql += " ORDER BY sent_at DESC, id DESC"
    return rows(sql, params)
