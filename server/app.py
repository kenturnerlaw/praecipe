from __future__ import annotations

import base64
import csv
import io
import json
import mimetypes
import posixpath
import re
import threading
import traceback
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse
from urllib.request import Request, urlopen

from . import db
from . import deadlines as rules
from . import email_sync
from .extract import extract
from .match import DOC_TYPES, guess_doc_type, match_matters
from .paths import FILES, MATTER_FILES, PUBLIC, ROOT, ensure_dirs

HOST = "127.0.0.1"
PORT = 12090


def _json(handler: BaseHTTPRequestHandler, code: int, payload: object) -> None:
    raw = json.dumps(payload, default=str).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(raw)


def _read_json(handler: BaseHTTPRequestHandler) -> dict:
    length = int(handler.headers.get("Content-Length") or 0)
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    if not raw:
        return {}
    return json.loads(raw.decode("utf-8"))


def _qid(path: str) -> int | None:
    m = re.search(r"/(\d+)(?:/|$)", path)
    return int(m.group(1)) if m else None


def _send_bytes(handler: BaseHTTPRequestHandler, data: bytes, filename: str, ctype: str | None = None) -> None:
    handler.send_response(200)
    handler.send_header("Content-Type", ctype or mimetypes.guess_type(filename)[0] or "application/octet-stream")
    handler.send_header("Content-Disposition", f'attachment; filename="{filename}"')
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def download_url(url: str, matter_id: int | None, message_id: int | None = None, doc_type: str = "service") -> dict:
    if not url.lower().startswith(("http://", "https://")):
        raise ValueError("Only http(s) URLs can be downloaded.")
    exists = db.one("SELECT * FROM files WHERE source_url = ? AND ifnull(matter_id,0) = ifnull(?,0)", (url, matter_id))
    if exists:
        return exists
    req = Request(url, headers={"User-Agent": "Praecipe/1.0 (practice mail; document download)"})
    with urlopen(req, timeout=45) as resp:
        data = resp.read()
        ctype = resp.headers.get("Content-Type", "application/octet-stream").split(";")[0]
        name = Path(urlparse(url).path).name or "service-document"
        if "." not in name:
            ext = mimetypes.guess_extension(ctype) or ".bin"
            name = name + ext
    kind = re.sub(r"[^a-z0-9_-]+", "", (doc_type or "service").lower()) or "service"
    dest_root = MATTER_FILES / str(matter_id or "unfiled") / kind
    dest_root.mkdir(parents=True, exist_ok=True)
    target = dest_root / name
    n = 1
    while target.exists():
        target = dest_root / f"{target.stem}-{n}{target.suffix}"
        n += 1
    target.write_bytes(data)
    file_id = db.execute(
        """INSERT INTO files (matter_id, message_id, filename, path, source, source_url, doc_type, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (matter_id, message_id, target.name, str(target), "url", url, kind, db.utcnow()),
    )
    return {"id": file_id, "filename": target.name, "path": str(target), "size": len(data), "doc_type": kind}


def apply_practice(message_id: int) -> dict:
    msg = db.one("SELECT * FROM messages WHERE id = ?", (message_id,))
    if not msg:
        raise ValueError("Message not found")
    found = extract(msg["subject"], msg["body_text"] or msg["body_html"] or "", msg.get("sent_at"))
    added_events = []
    downloaded = []
    auto_docket = db.setting("auto_docket", "1") != "0"
    auto_dl = db.setting("auto_download_service", "0") == "1"
    if auto_docket:
        for e in found.get("events") or []:
            exists = db.one(
                "SELECT id FROM events WHERE message_id = ? AND start_at LIKE ?",
                (message_id, (e.get("date") or "") + "%"),
            )
            if exists:
                continue
            eid = db.execute(
                """INSERT INTO events (matter_id, message_id, title, event_type, start_at, all_day, source, notes, remind_minutes, created_at)
                   VALUES (?, ?, ?, ?, ?, 1, 'email', ?, 30, ?)""",
                (
                    msg.get("matter_id"),
                    message_id,
                    e.get("title") or "Date from mail",
                    e.get("event_type") or "appointment",
                    e.get("date"),
                    e.get("context") or "",
                    db.utcnow(),
                ),
            )
            added_events.append(eid)
        for d in found.get("deadlines") or []:
            if not d.get("trigger"):
                continue
            result = rules.compute(d["rule_id"], date.fromisoformat(d["trigger"][:10]), service_mail_or_email=True)
            exists = db.one(
                "SELECT id FROM events WHERE message_id = ? AND start_at = ?",
                (message_id, result["due"]),
            )
            if exists:
                continue
            result = rules.compute(d["rule_id"], date.fromisoformat(d["trigger"][:10]), service_mail_or_email=True)
            eid = db.execute(
                """INSERT INTO events (matter_id, message_id, title, event_type, start_at, all_day, rule_cite, source, notes, remind_minutes, created_at)
                   VALUES (?, ?, ?, 'deadline', ?, 1, ?, 'computed', ?, 30, ?)""",
                (
                    msg.get("matter_id"),
                    message_id,
                    result["title"] + " due",
                    result["due"],
                    result["rule"],
                    result["note"],
                    db.utcnow(),
                ),
            )
            added_events.append(eid)
    if auto_dl:
        for u in found.get("urls") or []:
            if not u.get("service_likely"):
                continue
            try:
                downloaded.append(download_url(u["url"], msg.get("matter_id"), message_id))
            except Exception as exc:
                downloaded.append({"url": u["url"], "error": str(exc)})
    return {"extract": found, "added_events": added_events, "downloaded": downloaded}


def file_and_bill(message_id: int, payload: dict) -> dict:
    msg = db.one("SELECT * FROM messages WHERE id = ?", (message_id,))
    if not msg:
        raise ValueError("Message not found")
    matter_id = payload.get("matter_id") or msg.get("matter_id")
    if not matter_id:
        raise ValueError("Pick a matter first.")
    matter_id = int(matter_id)
    matter = db.one("SELECT * FROM matters WHERE id = ?", (matter_id,))
    if not matter:
        raise ValueError("Matter not found.")
    names = [a["filename"] for a in db.rows("SELECT filename FROM attachments WHERE message_id = ?", (message_id,))]
    doc_type = payload.get("doc_type") or guess_doc_type(msg, names)
    out: dict = {"ok": True, "matter_id": matter_id, "doc_type": doc_type, "connected": False, "saved": [], "downloaded": [], "email": None, "time": None}

    if payload.get("connect", True):
        db.execute("UPDATE messages SET matter_id = ? WHERE id = ?", (matter_id, message_id))
        db.execute("UPDATE events SET matter_id = ? WHERE message_id = ? AND matter_id IS NULL", (matter_id, message_id))
        out["connected"] = True

    if payload.get("save", True):
        out["saved"] = email_sync.save_attachments_to_matter(message_id, matter_id, doc_type)

    if payload.get("download_urls", True):
        found = extract(msg["subject"], msg["body_text"] or msg["body_html"] or "", msg.get("sent_at"))
        for u in found.get("urls") or []:
            if payload.get("urls"):
                if u["url"] not in payload["urls"]:
                    continue
            elif not u.get("service_likely"):
                continue
            try:
                out["downloaded"].append(download_url(u["url"], matter_id, message_id, doc_type))
            except Exception as exc:
                out["downloaded"].append({"url": u["url"], "error": str(exc)})

    if payload.get("email_client"):
        client = (payload.get("client_email") or matter.get("client_email") or "").strip()
        if not client:
            out["email"] = {"ok": False, "error": "No client email on this matter."}
        else:
            cover = payload.get("client_body") or (
                f"{matter.get('client_name') or 'Client'}:\n\n"
                f"FYI on {matter.get('style') or matter.get('case_no') or 'your matter'}.\n"
                f"Subject: {msg.get('subject')}\nFrom: {msg.get('from_addr')}\n\n"
            )
            quoted = email_sync.quote_original(msg, "forward")
            sent = email_sync.send_mail(
                client,
                quoted["subject"] if quoted["subject"].lower().startswith("fwd") else f"FW: {msg.get('subject') or ''}",
                cover + quoted["body"],
                matter_id=matter_id,
            )
            out["email"] = sent

    if payload.get("time", True):
        minutes = payload.get("minutes")
        running = db.one("SELECT * FROM time_entries WHERE running = 1 ORDER BY id DESC")
        if running and (not running.get("message_id") or running.get("message_id") == message_id):
            start = datetime.fromisoformat(running["started_at"])
            end = datetime.fromisoformat(db.utcnow())
            minutes = minutes or max(0.1, round((end - start).total_seconds() / 60.0, 1))
            db.execute(
                "UPDATE time_entries SET ended_at=?, minutes=?, running=0, matter_id=?, message_id=?, description=? WHERE id=?",
                (
                    end.isoformat(),
                    minutes,
                    matter_id,
                    message_id,
                    payload.get("time_description") or running["description"] or f"Email: {msg.get('subject')}",
                    running["id"],
                ),
            )
            out["time"] = db.one("SELECT * FROM time_entries WHERE id = ?", (running["id"],))
        else:
            minutes = float(minutes or 12)
            rate = matter.get("rate") or db.setting("default_rate") or 0
            tid = db.execute(
                """INSERT INTO time_entries (matter_id, message_id, started_at, ended_at, minutes, description, activity, rate, running, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)""",
                (
                    matter_id,
                    message_id,
                    db.utcnow(),
                    db.utcnow(),
                    minutes,
                    payload.get("time_description") or f"Email: {msg.get('subject')}",
                    payload.get("activity") or "email",
                    float(rate or 0),
                    db.utcnow(),
                ),
            )
            out["time"] = db.one("SELECT * FROM time_entries WHERE id = ?", (tid,))
    return out


def ics_for_events(items: list[dict]) -> str:
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Praecipe//Family Law Docket//EN",
        "CALSCALE:GREGORIAN",
    ]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for ev in items:
        start = ev.get("start_at") or ""
        title = (ev.get("title") or "Event").replace("\n", " ")
        desc = f"{ev.get('rule_cite') or ''} {ev.get('notes') or ''}".replace("\n", " ")
        lines += ["BEGIN:VEVENT", f"UID:praecipe-{ev['id']}@local", f"DTSTAMP:{stamp}", f"SUMMARY:{title}", f"DESCRIPTION:{desc}"]
        loc = ev.get("location") or ""
        if loc:
            lines.append(f"LOCATION:{loc}")
        if ev.get("all_day") or len(start) <= 10:
            day = start[:10].replace("-", "")
            if day:
                lines.append(f"DTSTART;VALUE=DATE:{day}")
        else:
            dt = re.sub(r"[-:]", "", start[:19]).replace("T", "T")
            if "T" not in dt and len(dt) >= 8:
                dt = dt[:8] + "T090000"
            lines.append(f"DTSTART:{dt}")
            end = ev.get("end_at") or ""
            if end:
                edt = re.sub(r"[-:]", "", end[:19])
                lines.append(f"DTEND:{edt}")
        lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")
    return "\r\n".join(lines) + "\r\n"


def reminders() -> list[dict]:
    now = datetime.now().astimezone()
    out = []
    for ev in db.rows("SELECT * FROM events WHERE dismissed = 0"):
        raw = ev.get("start_at") or ""
        try:
            if len(raw) <= 10:
                start = datetime.fromisoformat(raw[:10]).replace(hour=9, minute=0)
            else:
                start = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            if start.tzinfo is None:
                start = start.replace(tzinfo=now.tzinfo)
        except ValueError:
            continue
        minutes = int(ev.get("remind_minutes") or 30)
        delta = (start - now).total_seconds() / 60.0
        if -10 <= delta <= minutes:
            out.append(ev)
    return out


def handle_api(handler: BaseHTTPRequestHandler, method: str, path: str, query: dict) -> None:
    if path == "/api/health" and method == "GET":
        unseen = db.one("SELECT COUNT(*) AS n FROM messages WHERE seen = 0 AND deleted = 0")
        _json(handler, 200, {"ok": True, "name": "Praecipe", "port": PORT, "unseen": (unseen or {}).get("n") or 0})
        return

    if path == "/api/settings" and method == "GET":
        _json(handler, 200, db.get_settings())
        return
    if path == "/api/settings" and method == "POST":
        _json(handler, 200, db.save_settings(_read_json(handler)))
        return

    if path == "/api/matters" and method == "GET":
        _json(handler, 200, db.rows("SELECT * FROM matters ORDER BY status, case_no, id DESC"))
        return
    if path == "/api/matters" and method == "POST":
        p = _read_json(handler)
        style = p.get("style") or " v. ".join(x for x in (p.get("petitioner"), p.get("respondent")) if x) or "Untitled matter"
        mid = db.execute(
            """INSERT INTO matters (case_no, petitioner, respondent, style, court, county, division,
               status, opposing_counsel, rate, notes, client_email, client_name, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                p.get("case_no") or "",
                p.get("petitioner") or "",
                p.get("respondent") or "",
                style,
                p.get("court") or "Circuit Court",
                p.get("county") or "",
                p.get("division") or "Family",
                p.get("status") or "open",
                p.get("opposing_counsel") or "",
                float(p.get("rate") or 0),
                p.get("notes") or "",
                p.get("client_email") or "",
                p.get("client_name") or "",
                db.utcnow(),
            ),
        )
        _json(handler, 200, db.one("SELECT * FROM matters WHERE id = ?", (mid,)))
        return
    if path.startswith("/api/matters/") and method == "POST":
        mid = _qid(path)
        p = _read_json(handler)
        db.execute(
            """UPDATE matters SET case_no=?, petitioner=?, respondent=?, style=?, court=?, county=?,
               division=?, status=?, opposing_counsel=?, rate=?, notes=?, client_email=?, client_name=? WHERE id=?""",
            (
                p.get("case_no") or "",
                p.get("petitioner") or "",
                p.get("respondent") or "",
                p.get("style") or "",
                p.get("court") or "Circuit Court",
                p.get("county") or "",
                p.get("division") or "Family",
                p.get("status") or "open",
                p.get("opposing_counsel") or "",
                float(p.get("rate") or 0),
                p.get("notes") or "",
                p.get("client_email") or "",
                p.get("client_name") or "",
                mid,
            ),
        )
        _json(handler, 200, db.one("SELECT * FROM matters WHERE id = ?", (mid,)))
        return

    if path == "/api/mail/folders" and method == "GET":
        stored = db.rows("SELECT * FROM folders ORDER BY role, name")
        if not stored:
            stored = [
                {"name": "INBOX", "role": "inbox", "unseen": 0},
                {"name": "SENT", "role": "sent", "unseen": 0},
                {"name": "DRAFTS", "role": "drafts", "unseen": 0},
            ]
        counts = db.rows(
            """SELECT folder, SUM(CASE WHEN seen = 0 AND deleted = 0 THEN 1 ELSE 0 END) AS unseen,
                      SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END) AS total
               FROM messages GROUP BY folder"""
        )
        cmap = {c["folder"]: c for c in counts}
        for f in stored:
            c = cmap.get(f["name"]) or {}
            f["unseen"] = c.get("unseen") or 0
            f["total"] = c.get("total") or 0
        for extra in ("SENT", "DRAFTS"):
            if extra not in {f["name"] for f in stored}:
                c = cmap.get(extra) or {}
                stored.append({"name": extra, "role": extra.lower(), "unseen": c.get("unseen") or 0, "total": c.get("total") or 0})
        _json(handler, 200, stored)
        return

    if path == "/api/mail" and method == "GET":
        folder = (query.get("folder") or ["INBOX"])[0]
        q = (query.get("q") or [""])[0]
        unread = (query.get("unread") or [""])[0] == "1"
        flagged = (query.get("flagged") or [""])[0] == "1"
        items = db.search_mail(q, None if folder == "ALL" else folder)
        if unread:
            items = [m for m in items if not m.get("seen")]
        if flagged:
            items = [m for m in items if m.get("flagged")]
        _json(handler, 200, items)
        return
    if path == "/api/mail/sync" and method == "POST":
        _json(handler, 200, email_sync.sync_all())
        return
    if path == "/api/mail/send" and method == "POST":
        p = _read_json(handler)
        _json(
            handler,
            200,
            email_sync.send_mail(
                p.get("to") or "",
                p.get("subject") or "",
                p.get("body") or "",
                p.get("cc") or "",
                p.get("bcc") or "",
                p.get("matter_id") or None,
                p.get("in_reply_to") or "",
                p.get("references") or "",
                p.get("attachments") or [],
                bool(p.get("draft")),
                p.get("answered_id"),
            ),
        )
        return
    if path.startswith("/api/mail/") and path.endswith("/quote") and method == "GET":
        mid = _qid(path)
        mode = (query.get("mode") or ["reply"])[0]
        msg = db.one("SELECT * FROM messages WHERE id = ?", (mid,))
        if not msg:
            _json(handler, 404, {"error": "Message not found"})
            return
        _json(handler, 200, email_sync.quote_original(msg, mode))
        return
    if path.startswith("/api/mail/") and path.endswith("/apply-practice") and method == "POST":
        _json(handler, 200, apply_practice(_qid(path)))
        return
    if path.startswith("/api/mail/") and path.endswith("/read") and method == "POST":
        _json(handler, 200, email_sync.set_flag(_qid(path), "seen", True))
        return
    if path.startswith("/api/mail/") and path.endswith("/unread") and method == "POST":
        _json(handler, 200, email_sync.set_flag(_qid(path), "seen", False))
        return
    if path.startswith("/api/mail/") and path.endswith("/flag") and method == "POST":
        p = _read_json(handler)
        add = p.get("add", True)
        _json(handler, 200, email_sync.set_flag(_qid(path), "flagged", bool(add)))
        return
    if path.startswith("/api/mail/") and path.endswith("/delete") and method == "POST":
        _json(handler, 200, email_sync.delete_message(_qid(path)))
        return
    if path.startswith("/api/mail/") and path.endswith("/assign") and method == "POST":
        mid = _qid(path)
        p = _read_json(handler)
        db.execute("UPDATE messages SET matter_id = ? WHERE id = ?", (p.get("matter_id"), mid))
        _json(handler, 200, db.one("SELECT * FROM messages WHERE id = ?", (mid,)))
        return
    if path.startswith("/api/mail/") and path.endswith("/extract") and method == "GET":
        mid = _qid(path)
        msg = db.one("SELECT * FROM messages WHERE id = ?", (mid,))
        if not msg:
            _json(handler, 404, {"error": "Message not found"})
            return
        _json(handler, 200, extract(msg["subject"], msg["body_text"] or msg["body_html"] or "", msg.get("sent_at")))
        return
    if path.startswith("/api/mail/") and path.endswith("/file-and-bill") and method == "POST":
        _json(handler, 200, file_and_bill(_qid(path), _read_json(handler)))
        return
    if path.startswith("/api/mail/") and path.endswith("/match") and method == "GET":
        mid = _qid(path)
        msg = db.one("SELECT * FROM messages WHERE id = ?", (mid,))
        if not msg:
            _json(handler, 404, {"error": "Message not found"})
            return
        names = [a["filename"] for a in db.rows("SELECT filename FROM attachments WHERE message_id = ?", (mid,))]
        _json(handler, 200, {"matches": match_matters(msg), "doc_type": guess_doc_type(msg, names), "doc_types": DOC_TYPES})
        return
    if path.startswith("/api/mail/") and path.endswith("/file-attachments") and method == "POST":
        mid = _qid(path)
        p = _read_json(handler)
        matter_id = p.get("matter_id") or db.one("SELECT matter_id FROM messages WHERE id = ?", (mid,))["matter_id"]
        if not matter_id:
            _json(handler, 400, {"error": "Attach the message to a matter first."})
            return
        db.execute("UPDATE messages SET matter_id = ? WHERE id = ?", (matter_id, mid))
        saved = email_sync.save_attachments_to_matter(mid, int(matter_id), p.get("doc_type") or "correspondence")
        _json(handler, 200, {"ok": True, "saved": saved})
        return
    if path.startswith("/api/mail/") and method == "GET":
        mid = _qid(path)
        msg = db.one("SELECT * FROM messages WHERE id = ?", (mid,))
        if not msg:
            _json(handler, 404, {"error": "Message not found"})
            return
        msg["attachments"] = db.rows(
            "SELECT id, filename, mime, size, saved_path FROM attachments WHERE message_id = ?", (mid,)
        )
        names = [a["filename"] for a in msg["attachments"]]
        msg["matches"] = match_matters(msg)
        msg["doc_type"] = guess_doc_type(msg, names)
        msg["doc_types"] = DOC_TYPES
        matter = db.one("SELECT * FROM matters WHERE id = ?", (msg["matter_id"],)) if msg.get("matter_id") else None
        msg["client_email"] = (matter or {}).get("client_email") or ""
        _json(handler, 200, msg)
        return

    if path.startswith("/api/attachments/") and method == "GET":
        att = db.one("SELECT * FROM attachments WHERE id = ?", (_qid(path),))
        if not att or not att.get("saved_path") or not Path(att["saved_path"]).exists():
            _json(handler, 404, {"error": "Attachment not found"})
            return
        _send_bytes(handler, Path(att["saved_path"]).read_bytes(), att["filename"], att.get("mime"))
        return

    if path == "/api/contacts" and method == "GET":
        q = (query.get("q") or [""])[0].strip()
        if q:
            like = f"%{q}%"
            _json(
                handler,
                200,
                db.rows(
                    "SELECT * FROM contacts WHERE email LIKE ? OR name LIKE ? OR firm LIKE ? ORDER BY name, email LIMIT 100",
                    (like, like, like),
                ),
            )
        else:
            _json(handler, 200, db.rows("SELECT * FROM contacts ORDER BY name, email"))
        return
    if path == "/api/contacts" and method == "POST":
        p = _read_json(handler)
        cid = db.execute(
            """INSERT INTO contacts (name, email, phone, firm, notes, matter_id, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(email) DO UPDATE SET
                 name=excluded.name, phone=excluded.phone, firm=excluded.firm, notes=excluded.notes, matter_id=excluded.matter_id""",
            (
                p.get("name") or "",
                (p.get("email") or "").strip().lower(),
                p.get("phone") or "",
                p.get("firm") or "",
                p.get("notes") or "",
                p.get("matter_id"),
                db.utcnow(),
            ),
        )
        row = db.one("SELECT * FROM contacts WHERE id = ?", (cid,)) or db.one(
            "SELECT * FROM contacts WHERE email = ?", ((p.get("email") or "").strip().lower(),)
        )
        _json(handler, 200, row)
        return
    if path.startswith("/api/contacts/") and method == "POST":
        cid = _qid(path)
        p = _read_json(handler)
        db.execute(
            "UPDATE contacts SET name=?, email=?, phone=?, firm=?, notes=?, matter_id=? WHERE id=?",
            (
                p.get("name") or "",
                (p.get("email") or "").strip().lower(),
                p.get("phone") or "",
                p.get("firm") or "",
                p.get("notes") or "",
                p.get("matter_id"),
                cid,
            ),
        )
        _json(handler, 200, db.one("SELECT * FROM contacts WHERE id = ?", (cid,)))
        return
    if path.startswith("/api/contacts/") and method == "DELETE":
        db.execute("DELETE FROM contacts WHERE id = ?", (_qid(path),))
        _json(handler, 200, {"ok": True})
        return

    if path == "/api/files" and method == "GET":
        matter = (query.get("matter_id") or [None])[0]
        if matter:
            _json(handler, 200, db.rows("SELECT * FROM files WHERE matter_id = ? ORDER BY id DESC", (int(matter),)))
        else:
            _json(handler, 200, db.rows("SELECT * FROM files ORDER BY id DESC LIMIT 200"))
        return
    if path == "/api/files/download-url" and method == "POST":
        p = _read_json(handler)
        _json(handler, 200, download_url(p.get("url") or "", p.get("matter_id"), p.get("message_id")))
        return
    if path == "/api/files/upload" and method == "POST":
        p = _read_json(handler)
        matter_id = p.get("matter_id")
        dest = MATTER_FILES / str(matter_id or "unfiled")
        dest.mkdir(parents=True, exist_ok=True)
        saved = []
        for att in p.get("files") or []:
            data = base64.b64decode(att.get("data") or "")
            filename = Path(att.get("filename") or "upload").name
            target = dest / filename
            n = 1
            while target.exists():
                target = dest / f"{target.stem}-{n}{target.suffix}"
                n += 1
            target.write_bytes(data)
            fid = db.execute(
                """INSERT INTO files (matter_id, filename, path, source, created_at)
                   VALUES (?, ?, ?, 'upload', ?)""",
                (matter_id, target.name, str(target), db.utcnow()),
            )
            saved.append({"id": fid, "filename": target.name, "path": str(target)})
        _json(handler, 200, {"ok": True, "saved": saved})
        return
    if path.startswith("/api/files/") and path.endswith("/download") and method == "GET":
        row = db.one("SELECT * FROM files WHERE id = ?", (_qid(path),))
        if not row or not Path(row["path"]).exists():
            _json(handler, 404, {"error": "File not found"})
            return
        _send_bytes(handler, Path(row["path"]).read_bytes(), row["filename"])
        return

    if path == "/api/notes" and method == "GET":
        matter = (query.get("matter_id") or [None])[0]
        if matter:
            _json(handler, 200, db.rows("SELECT * FROM notes WHERE matter_id = ? ORDER BY updated_at DESC", (int(matter),)))
        else:
            _json(handler, 200, db.rows("SELECT * FROM notes ORDER BY updated_at DESC"))
        return
    if path == "/api/notes" and method == "POST":
        p = _read_json(handler)
        now = db.utcnow()
        nid = db.execute(
            "INSERT INTO notes (matter_id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            (p.get("matter_id"), p.get("title") or "Note", p.get("body") or "", now, now),
        )
        _json(handler, 200, db.one("SELECT * FROM notes WHERE id = ?", (nid,)))
        return
    if path.startswith("/api/notes/") and method == "POST":
        nid = _qid(path)
        p = _read_json(handler)
        db.execute(
            "UPDATE notes SET title=?, body=?, matter_id=?, updated_at=? WHERE id=?",
            (p.get("title") or "Note", p.get("body") or "", p.get("matter_id"), db.utcnow(), nid),
        )
        _json(handler, 200, db.one("SELECT * FROM notes WHERE id = ?", (nid,)))
        return
    if path.startswith("/api/notes/") and method == "DELETE":
        db.execute("DELETE FROM notes WHERE id = ?", (_qid(path),))
        _json(handler, 200, {"ok": True})
        return

    if path == "/api/time.csv" and method == "GET":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["id", "matter_id", "started_at", "ended_at", "minutes", "activity", "description", "rate", "fee", "billed"])
        for t in db.rows("SELECT * FROM time_entries WHERE running = 0 ORDER BY id"):
            fee = (t.get("rate") or 0) * (t.get("minutes") or 0) / 60
            w.writerow([t["id"], t["matter_id"], t["started_at"], t["ended_at"], t["minutes"], t["activity"], t["description"], t["rate"], round(fee, 2), t["billed"]])
        _send_bytes(handler, buf.getvalue().encode("utf-8"), "praecipe-time.csv", "text/csv")
        return
    if path == "/api/time" and method == "GET":
        _json(handler, 200, db.rows("SELECT * FROM time_entries ORDER BY id DESC LIMIT 400"))
        return
    if path == "/api/time/start" and method == "POST":
        p = _read_json(handler)
        running = db.one("SELECT * FROM time_entries WHERE running = 1 ORDER BY id DESC")
        if running:
            _json(handler, 200, running)
            return
        rate = p.get("rate")
        if not rate and p.get("matter_id"):
            m = db.one("SELECT rate FROM matters WHERE id = ?", (p["matter_id"],))
            rate = (m or {}).get("rate") or db.setting("default_rate") or 0
        tid = db.execute(
            """INSERT INTO time_entries (matter_id, message_id, started_at, minutes, description, activity, rate, running, created_at)
               VALUES (?, ?, ?, 0, ?, ?, ?, 1, ?)""",
            (
                p.get("matter_id"),
                p.get("message_id"),
                db.utcnow(),
                p.get("description") or "",
                p.get("activity") or "email",
                float(rate or 0),
                db.utcnow(),
            ),
        )
        _json(handler, 200, db.one("SELECT * FROM time_entries WHERE id = ?", (tid,)))
        return
    if path == "/api/time/stop" and method == "POST":
        running = db.one("SELECT * FROM time_entries WHERE running = 1 ORDER BY id DESC")
        if not running:
            _json(handler, 200, {"ok": True, "stopped": None})
            return
        start = datetime.fromisoformat(running["started_at"])
        end = datetime.fromisoformat(db.utcnow())
        minutes = max(0.1, round((end - start).total_seconds() / 60.0, 1))
        p = _read_json(handler)
        desc = p.get("description") if p.get("description") else running["description"]
        db.execute(
            "UPDATE time_entries SET ended_at=?, minutes=?, running=0, description=? WHERE id=?",
            (end.isoformat(), minutes, desc or running["description"], running["id"]),
        )
        _json(handler, 200, db.one("SELECT * FROM time_entries WHERE id = ?", (running["id"],)))
        return
    if path.startswith("/api/time/") and path.endswith("/billed") and method == "POST":
        tid = _qid(path)
        p = _read_json(handler)
        db.execute("UPDATE time_entries SET billed = ? WHERE id = ?", (1 if p.get("billed", True) else 0, tid))
        _json(handler, 200, db.one("SELECT * FROM time_entries WHERE id = ?", (tid,)))
        return
    if path == "/api/time" and method == "POST":
        p = _read_json(handler)
        tid = db.execute(
            """INSERT INTO time_entries (matter_id, message_id, started_at, ended_at, minutes, description, activity, billed, rate, running, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)""",
            (
                p.get("matter_id"),
                p.get("message_id"),
                p.get("started_at") or db.utcnow(),
                p.get("ended_at") or db.utcnow(),
                float(p.get("minutes") or 0),
                p.get("description") or "",
                p.get("activity") or "legal services",
                1 if p.get("billed") else 0,
                float(p.get("rate") or db.setting("default_rate") or 0),
                db.utcnow(),
            ),
        )
        _json(handler, 200, db.one("SELECT * FROM time_entries WHERE id = ?", (tid,)))
        return

    if path == "/api/reminders" and method == "GET":
        _json(handler, 200, reminders())
        return
    if path == "/api/events" and method == "GET":
        _json(handler, 200, db.rows("SELECT * FROM events ORDER BY start_at, id"))
        return
    if path == "/api/events" and method == "POST":
        p = _read_json(handler)
        eid = db.execute(
            """INSERT INTO events (matter_id, message_id, title, event_type, start_at, end_at, all_day, location, rule_cite, source, notes, remind_minutes, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                p.get("matter_id"),
                p.get("message_id"),
                p.get("title") or "Event",
                p.get("event_type") or "appointment",
                p.get("start_at"),
                p.get("end_at"),
                1 if p.get("all_day", False) else 0,
                p.get("location") or "",
                p.get("rule_cite") or "",
                p.get("source") or "manual",
                p.get("notes") or "",
                int(p.get("remind_minutes") if p.get("remind_minutes") is not None else 30),
                db.utcnow(),
            ),
        )
        _json(handler, 200, db.one("SELECT * FROM events WHERE id = ?", (eid,)))
        return
    if path.startswith("/api/events/") and path.endswith("/dismiss") and method == "POST":
        db.execute("UPDATE events SET dismissed = 1 WHERE id = ?", (_qid(path),))
        _json(handler, 200, {"ok": True})
        return
    if path.startswith("/api/events/") and method == "POST":
        eid = _qid(path)
        p = _read_json(handler)
        db.execute(
            """UPDATE events SET title=?, event_type=?, start_at=?, end_at=?, all_day=?, location=?, notes=?,
               matter_id=?, remind_minutes=? WHERE id=?""",
            (
                p.get("title") or "Event",
                p.get("event_type") or "appointment",
                p.get("start_at"),
                p.get("end_at"),
                1 if p.get("all_day") else 0,
                p.get("location") or "",
                p.get("notes") or "",
                p.get("matter_id"),
                int(p.get("remind_minutes") if p.get("remind_minutes") is not None else 30),
                eid,
            ),
        )
        _json(handler, 200, db.one("SELECT * FROM events WHERE id = ?", (eid,)))
        return
    if path.startswith("/api/events/") and method == "DELETE":
        eid = _qid(path)
        db.execute("DELETE FROM events WHERE id = ?", (eid,))
        _json(handler, 200, {"ok": True})
        return

    if path == "/api/deadlines/catalog" and method == "GET":
        _json(handler, 200, rules.CATALOG)
        return
    if path == "/api/deadlines/compute" and method == "POST":
        p = _read_json(handler)
        trigger = date.fromisoformat(p["trigger"])
        result = rules.compute(
            p.get("rule_id") or "custom",
            trigger,
            days=p.get("days"),
            service_mail_or_email=bool(p.get("service_mail_or_email")),
            direction=p.get("direction"),
            unit=p.get("unit"),
            statutory=p.get("statutory"),
        )
        if p.get("save"):
            eid = db.execute(
                """INSERT INTO events (matter_id, message_id, title, event_type, start_at, all_day, rule_cite, source, notes, remind_minutes, created_at)
                   VALUES (?, ?, ?, 'deadline', ?, 1, ?, 'computed', ?, 30, ?)""",
                (
                    p.get("matter_id"),
                    p.get("message_id"),
                    result["title"] + " due",
                    result["due"],
                    result["rule"],
                    result["note"],
                    db.utcnow(),
                ),
            )
            result["event_id"] = eid
        _json(handler, 200, result)
        return

    if path == "/api/calendar.ics" and method == "GET":
        body = ics_for_events(db.rows("SELECT * FROM events ORDER BY start_at")).encode("utf-8")
        _send_bytes(handler, body, "praecipe.ics", "text/calendar; charset=utf-8")
        return

    _json(handler, 404, {"error": "Unknown API path", "path": path})


class Handler(BaseHTTPRequestHandler):
    server_version = "Praecipe/1.0"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[praecipe] {self.address_string()} {fmt % args}", flush=True)

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def do_DELETE(self) -> None:
        self._dispatch("DELETE")

    def _dispatch(self, method: str) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)
        try:
            if path.startswith("/api/"):
                handle_api(self, method, path, query)
                return
            self._static(path)
        except Exception as exc:
            traceback.print_exc()
            if path.startswith("/api/"):
                _json(self, 500, {"error": str(exc)})
            else:
                body = f"Server error: {exc}".encode()
                self.send_response(500)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

    def _static(self, path: str) -> None:
        if path == "/":
            path = "/index.html"
        rel = posixpath.normpath(path).lstrip("/")
        target = (PUBLIC / rel).resolve()
        if PUBLIC.resolve() not in target.parents and target != PUBLIC.resolve():
            self.send_error(403)
            return
        if not target.exists() or not target.is_file():
            self.send_error(404)
            return
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def _poll_loop() -> None:
    import time

    time.sleep(15)
    while True:
        try:
            if email_sync.configured():
                email_sync.sync_all()
        except Exception:
            traceback.print_exc()
        time.sleep(120)


def main() -> None:
    ensure_dirs()
    FILES.mkdir(parents=True, exist_ok=True)
    db.connect()
    threading.Thread(target=_poll_loop, daemon=True, name="praecipe-sync").start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Praecipe is running at http://{HOST}:{PORT}", flush=True)
    print(f"Matter files: {MATTER_FILES}", flush=True)
    print(f"Project root: {ROOT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Praecipe.")
        server.server_close()
