from __future__ import annotations

import email
import imaplib
import json
import re
import smtplib
import ssl
import threading
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import formataddr, getaddresses, make_msgid, parsedate_to_datetime
from pathlib import Path
from typing import Any, Optional

from . import db
from .paths import MAIL_FILES, ensure_dirs

_sync_lock = threading.Lock()

FOLDER_ROLES = (
    ("inbox", ("inbox",)),
    ("sent", ("sent", "sent items", "sent mail", "[gmail]/sent mail")),
    ("drafts", ("drafts", "[gmail]/drafts")),
    ("trash", ("trash", "deleted", "deleted items", "[gmail]/trash")),
    ("junk", ("junk", "spam", "[gmail]/spam")),
    ("archive", ("archive", "[gmail]/all mail")),
)


def _decode(value: Any) -> str:
    if value is None:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return str(value)


def _addr(msg: email.message.Message, header: str) -> str:
    return _decode(msg.get(header, "") or "")


def _body_and_files(msg: email.message.Message) -> tuple[str, str, list[dict[str, Any]]]:
    text = ""
    html = ""
    files: list[dict[str, Any]] = []
    if msg.is_multipart():
        for part in msg.walk():
            ctype = (part.get_content_type() or "").lower()
            disp = str(part.get("Content-Disposition") or "")
            filename = part.get_filename()
            if filename or "attachment" in disp.lower():
                payload = part.get_payload(decode=True) or b""
                files.append(
                    {
                        "filename": _decode(filename) or "attachment",
                        "mime": ctype,
                        "size": len(payload),
                        "content": payload,
                    }
                )
                continue
            if ctype == "text/plain" and not text:
                payload = part.get_payload(decode=True) or b""
                charset = part.get_content_charset() or "utf-8"
                text = payload.decode(charset, errors="replace")
            elif ctype == "text/html" and not html:
                payload = part.get_payload(decode=True) or b""
                charset = part.get_content_charset() or "utf-8"
                html = payload.decode(charset, errors="replace")
    else:
        payload = msg.get_payload(decode=True) or b""
        charset = msg.get_content_charset() or "utf-8"
        body = payload.decode(charset, errors="replace")
        if (msg.get_content_type() or "") == "text/html":
            html = body
        else:
            text = body
    return text, html, files


def _sent_iso(msg: email.message.Message) -> str:
    raw = msg.get("Date")
    if not raw:
        return db.utcnow()
    try:
        dt = parsedate_to_datetime(raw)
        return dt.replace(microsecond=0).isoformat()
    except Exception:
        return db.utcnow()


def configured() -> bool:
    return bool(db.setting("imap_host") and db.setting("imap_user") and db.setting("imap_password"))


def _imap() -> imaplib.IMAP4:
    host = db.setting("imap_host")
    port = int(db.setting("imap_port") or "993")
    user = db.setting("imap_user")
    password = db.setting("imap_password")
    timeout = 60
    if db.setting("imap_tls", "ssl") == "none":
        client: imaplib.IMAP4 = imaplib.IMAP4(host, port, timeout=timeout)
    else:
        client = imaplib.IMAP4_SSL(host, port, timeout=timeout)
    client.login(user, password)
    try:
        client.enable("UTF8=ACCEPT")
    except Exception:
        pass
    return client


def _parse_list_line(raw: bytes) -> Optional[dict[str, str]]:
    line = raw.decode("utf-8", errors="replace")
    m = re.match(r'^\((.*?)\)\s+"([^"]+)"\s+(.*)$', line)
    if not m:
        m = re.match(r"^\((.*?)\)\s+(\S+)\s+(.*)$", line)
    if not m:
        return None
    attrs, delim, name = m.group(1), m.group(2), m.group(3).strip()
    if name.startswith('"') and name.endswith('"'):
        name = name[1:-1]
    if "\\Noselect" in attrs or "\\NonExistent" in attrs:
        return None
    role = ""
    low = name.lower()
    attr_l = attrs.lower()
    if "\\inbox" in attr_l or low == "inbox":
        role = "inbox"
    elif "\\sent" in attr_l:
        role = "sent"
    elif "\\drafts" in attr_l:
        role = "drafts"
    elif "\\trash" in attr_l:
        role = "trash"
    elif "\\junk" in attr_l:
        role = "junk"
    elif "\\archive" in attr_l or "\\all" in attr_l:
        role = "archive"
    else:
        for r, names in FOLDER_ROLES:
            if low in names or any(n in low for n in names if n != "inbox"):
                role = r
                break
    if role == "archive" and "all mail" in low:
        return None
    return {"name": name, "delimiter": delim, "attrs": attrs, "role": role}


def _quote_folder(name: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9]+", name):
        return name
    return f'"{name}"'


def _parse_flags(meta: bytes) -> list[str]:
    m = re.search(rb"FLAGS \((.*?)\)", meta)
    if not m:
        return []
    out = []
    for tok in m.group(1).split():
        out.append(tok.decode("utf-8", errors="replace").lstrip("\\").lower())
    return out


def harvest_addresses(*headers: str) -> None:
    for header in headers:
        if not header:
            continue
        for name, addr in getaddresses([header]):
            email_addr = (addr or "").strip().lower()
            if not email_addr or "@" not in email_addr:
                continue
            existing = db.one("SELECT id, name FROM contacts WHERE email = ?", (email_addr,))
            if existing:
                if name and not existing.get("name"):
                    db.execute("UPDATE contacts SET name = ? WHERE id = ?", (name, existing["id"]))
                continue
            db.execute(
                "INSERT INTO contacts (name, email, created_at) VALUES (?, ?, ?)",
                (name or "", email_addr, db.utcnow()),
            )


def _store_message(folder: str, uid: str, flags: list[str], msg: email.message.Message) -> Optional[int]:
    mid = _decode(msg.get("Message-ID") or "") or f"imap-{folder}-{uid}"
    existing = db.one("SELECT id FROM messages WHERE folder = ? AND message_id = ?", (folder, mid))
    text, html, files = _body_and_files(msg)
    snippet = " ".join((text or re.sub("<[^>]+>", " ", html or "")).split())[:280]
    seen = 1 if "seen" in flags else 0
    flagged = 1 if "flagged" in flags else 0
    draft = 1 if "draft" in flags else 0
    answered = 1 if "answered" in flags else 0
    payload = (
        uid,
        folder,
        mid,
        _decode(msg.get("In-Reply-To") or ""),
        _decode(msg.get("References") or ""),
        _addr(msg, "From"),
        _addr(msg, "To"),
        _addr(msg, "Cc"),
        _addr(msg, "Bcc"),
        _addr(msg, "Reply-To"),
        _decode(msg.get("Subject") or "(no subject)"),
        _sent_iso(msg),
        snippet,
        text,
        html,
        json.dumps(flags),
        1 if files else 0,
        seen,
        flagged,
        draft,
        answered,
        db.utcnow(),
    )
    if existing:
        db.execute(
            """UPDATE messages SET imap_uid=?, in_reply_to=?, references_header=?, from_addr=?, to_addr=?,
               cc_addr=?, bcc_addr=?, reply_to=?, subject=?, sent_at=?, snippet=?,
               body_text=CASE WHEN body_text = '' THEN ? ELSE body_text END,
               body_html=CASE WHEN body_html = '' THEN ? ELSE body_html END,
               flags=?, has_attachments=?, seen=?, flagged=?, draft=?, answered=?, synced_at=?
               WHERE id=?""",
            (
                uid,
                _decode(msg.get("In-Reply-To") or ""),
                _decode(msg.get("References") or ""),
                _addr(msg, "From"),
                _addr(msg, "To"),
                _addr(msg, "Cc"),
                _addr(msg, "Bcc"),
                _addr(msg, "Reply-To"),
                _decode(msg.get("Subject") or "(no subject)"),
                _sent_iso(msg),
                snippet,
                text,
                html,
                json.dumps(flags),
                1 if files else 0,
                seen,
                flagged,
                draft,
                answered,
                db.utcnow(),
                existing["id"],
            ),
        )
        msg_id = existing["id"]
    else:
        msg_id = db.execute(
            """INSERT INTO messages
               (imap_uid, folder, message_id, in_reply_to, references_header, from_addr, to_addr,
                cc_addr, bcc_addr, reply_to, subject, sent_at, snippet, body_text, body_html, flags,
                has_attachments, seen, flagged, draft, answered, synced_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            payload,
        )
        folder_dir = MAIL_FILES / str(msg_id)
        if files:
            folder_dir.mkdir(parents=True, exist_ok=True)
        for f in files:
            safe = Path(f["filename"]).name or "attachment"
            path = folder_dir / safe
            path.write_bytes(f["content"])
            db.execute(
                """INSERT INTO attachments (message_id, filename, mime, size, saved_path)
                   VALUES (?, ?, ?, ?, ?)""",
                (msg_id, safe, f["mime"], f["size"], str(path)),
            )
    db.fts_upsert(msg_id)
    harvest_addresses(_addr(msg, "From"), _addr(msg, "To"), _addr(msg, "Cc"))
    return msg_id if not existing else None


def list_folders(client: Optional[imaplib.IMAP4] = None) -> list[dict[str, str]]:
    own = client is None
    if own:
        client = _imap()
    try:
        typ, data = client.list()
        folders = []
        if typ == "OK" and data:
            for raw in data:
                if not raw:
                    continue
                parsed = _parse_list_line(raw if isinstance(raw, bytes) else bytes(raw))
                if parsed:
                    folders.append(parsed)
        if not any(f["name"].upper() == "INBOX" for f in folders):
            folders.insert(0, {"name": "INBOX", "delimiter": "/", "attrs": "", "role": "inbox"})
        for f in folders:
            db.execute(
                """INSERT INTO folders(name, role, delimiter, attrs, last_uid, unseen)
                   VALUES (?, ?, ?, ?, 0, 0)
                   ON CONFLICT(name) DO UPDATE SET role=excluded.role, delimiter=excluded.delimiter, attrs=excluded.attrs""",
                (f["name"], f["role"], f["delimiter"], f["attrs"]),
            )
        return folders
    finally:
        if own:
            try:
                client.logout()
            except Exception:
                pass


def _sync_folder(client: imaplib.IMAP4, folder: str, limit: int) -> int:
    quoted = _quote_folder(folder)
    typ, _ = client.select(quoted, readonly=True)
    if typ != "OK":
        return 0
    row = db.one("SELECT last_uid FROM folders WHERE name = ?", (folder,))
    last_uid = int((row or {}).get("last_uid") or 0)
    typ, data = client.uid("search", None, "ALL")
    if typ != "OK" or not data or not data[0]:
        return 0
    uids = [int(x) for x in data[0].split()]
    if last_uid:
        new_uids = [u for u in uids if u > last_uid]
        if not new_uids:
            unseen = db.one(
                "SELECT COUNT(*) AS n FROM messages WHERE folder = ? AND seen = 0 AND deleted = 0",
                (folder,),
            )
            db.execute("UPDATE folders SET unseen = ? WHERE name = ?", ((unseen or {}).get("n") or 0, folder))
            return 0
        uids = new_uids
    else:
        uids = uids[-limit:]
    added = 0
    max_uid = last_uid
    for uid in uids:
        typ, fetched = client.uid("fetch", str(uid), "(FLAGS RFC822.PEEK)")
        if typ != "OK" or not fetched:
            continue
        meta = b""
        raw = None
        for item in fetched:
            if isinstance(item, tuple) and len(item) >= 2:
                meta = item[0] if isinstance(item[0], (bytes, bytearray)) else b""
                if isinstance(item[1], (bytes, bytearray)):
                    raw = item[1]
                    break
        if not raw:
            continue
        flags = _parse_flags(meta)
        msg = email.message_from_bytes(raw)
        if _store_message(folder, str(uid), flags, msg) is not None:
            added += 1
        max_uid = max(max_uid, uid)
    unseen = db.one(
        "SELECT COUNT(*) AS n FROM messages WHERE folder = ? AND seen = 0 AND deleted = 0",
        (folder,),
    )
    db.execute(
        """INSERT INTO folders(name, last_uid, unseen) VALUES (?, ?, ?)
           ON CONFLICT(name) DO UPDATE SET last_uid=excluded.last_uid, unseen=excluded.unseen""",
        (folder, max_uid, (unseen or {}).get("n") or 0),
    )
    return added


def sync_all(limit: int = 250) -> dict[str, Any]:
    if not configured():
        return {"ok": False, "error": "IMAP is not configured. Open Settings and add your mail host.", "added": 0}
    if not _sync_lock.acquire(blocking=False):
        return {"ok": True, "added": 0, "busy": True}
    ensure_dirs()
    try:
        client = _imap()
        try:
            folders = list_folders(client)
            added = 0
            synced = []
            for f in folders:
                if f.get("role") in ("junk", "trash", "archive"):
                    continue
                cap = limit if f.get("role") in ("inbox", "sent", "") or f["name"].upper() == "INBOX" else min(80, limit)
                n = _sync_folder(client, f["name"], cap)
                added += n
                synced.append(f["name"])
            total = db.one("SELECT COUNT(*) AS n FROM messages WHERE deleted = 0")["n"]
            unseen = db.one("SELECT COUNT(*) AS n FROM messages WHERE seen = 0 AND deleted = 0")["n"]
            return {"ok": True, "added": added, "total": total, "unseen": unseen, "folders": synced}
        finally:
            try:
                client.logout()
            except Exception:
                pass
    finally:
        _sync_lock.release()


def sync_inbox(limit: int = 250) -> dict[str, Any]:
    return sync_all(limit)


def _with_writable(folder: str):
    client = _imap()
    typ, _ = client.select(_quote_folder(folder), readonly=False)
    if typ != "OK":
        try:
            client.logout()
        except Exception:
            pass
        raise RuntimeError(f"Could not open folder {folder}")
    return client


def set_flag(message_local_id: int, flag: str, add: bool = True) -> dict[str, Any]:
    msg = db.one("SELECT * FROM messages WHERE id = ?", (message_local_id,))
    if not msg:
        return {"ok": False, "error": "Message not found"}
    imap_flag = {"seen": "\\Seen", "flagged": "\\Flagged", "deleted": "\\Deleted", "answered": "\\Answered"}.get(flag)
    if msg.get("imap_uid") and configured() and imap_flag and msg.get("folder") not in ("SENT", "DRAFTS"):
        client = _with_writable(msg["folder"])
        try:
            op = "+FLAGS" if add else "-FLAGS"
            client.uid("store", str(msg["imap_uid"]), op, f"({imap_flag})")
        finally:
            try:
                client.logout()
            except Exception:
                pass
    col = {"seen": "seen", "flagged": "flagged", "deleted": "deleted", "answered": "answered"}[flag]
    db.execute(f"UPDATE messages SET {col} = ? WHERE id = ?", (1 if add else 0, message_local_id))
    return {"ok": True, "id": message_local_id, col: 1 if add else 0}


def delete_message(message_local_id: int) -> dict[str, Any]:
    msg = db.one("SELECT * FROM messages WHERE id = ?", (message_local_id,))
    if not msg:
        return {"ok": False, "error": "Message not found"}
    trash = db.one("SELECT name FROM folders WHERE role = 'trash'")
    if msg.get("imap_uid") and configured() and msg.get("folder") not in ("SENT", "DRAFTS"):
        client = _with_writable(msg["folder"])
        try:
            if trash:
                try:
                    client.uid("copy", str(msg["imap_uid"]), _quote_folder(trash["name"]))
                except Exception:
                    pass
            client.uid("store", str(msg["imap_uid"]), "+FLAGS", "(\\Deleted)")
            try:
                client.expunge()
            except Exception:
                pass
        finally:
            try:
                client.logout()
            except Exception:
                pass
    db.execute("UPDATE messages SET deleted = 1, seen = 1 WHERE id = ?", (message_local_id,))
    return {"ok": True}


def _own_address() -> str:
    return (db.setting("email_address") or db.setting("imap_user") or "").lower()


def _append_sent(raw: bytes) -> None:
    sent = db.one("SELECT name FROM folders WHERE role = 'sent'")
    if not sent or not configured():
        return
    client = _imap()
    try:
        client.append(_quote_folder(sent["name"]), "(\\Seen)", None, raw)
    except Exception:
        pass
    finally:
        try:
            client.logout()
        except Exception:
            pass


def send_mail(
    to_addr: str,
    subject: str,
    body: str,
    cc: str = "",
    bcc: str = "",
    matter_id: Optional[int] = None,
    in_reply_to: str = "",
    references: str = "",
    attachments: Optional[list[dict[str, Any]]] = None,
    save_draft: bool = False,
    reply_all_answered_id: Optional[int] = None,
) -> dict[str, Any]:
    from_addr = db.setting("email_address") or db.setting("imap_user")
    display = db.setting("display_name") or from_addr or ""
    signature = db.setting("signature")
    if signature and signature not in (body or ""):
        body = (body or "").rstrip() + "\n\n" + signature

    msg = EmailMessage()
    msgid = make_msgid(domain=(from_addr.split("@")[-1] if from_addr and "@" in from_addr else "localhost"))
    msg["From"] = formataddr((display, from_addr or "praecipe@localhost"))
    msg["To"] = to_addr
    if cc:
        msg["Cc"] = cc
    if bcc:
        msg["Bcc"] = bcc
    msg["Subject"] = subject
    msg["Message-ID"] = msgid
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
    if references:
        msg["References"] = references
    msg.set_content(body or "")
    for att in attachments or []:
        data = att.get("bytes")
        if data is None and att.get("data"):
            import base64

            data = base64.b64decode(att["data"])
        if not data:
            continue
        filename = att.get("filename") or "attachment"
        mime = (att.get("mime") or "application/octet-stream").split("/")
        main, sub = (mime + ["octet-stream"])[:2]
        if main not in ("text", "image", "audio", "video", "application"):
            main, sub = "application", "octet-stream"
        msg.add_attachment(data, maintype=main, subtype=sub, filename=filename)

    if save_draft:
        local_id = _save_local(msg, "DRAFTS", to_addr, cc, bcc, subject, body, matter_id, True, attachments or [])
        return {"ok": True, "id": local_id, "draft": True}

    host = db.setting("smtp_host")
    if not host:
        return {"ok": False, "error": "SMTP is not configured."}
    port = int(db.setting("smtp_port") or "587")
    user = db.setting("smtp_user") or db.setting("imap_user")
    password = db.setting("smtp_password") or db.setting("imap_password")
    mode = db.setting("smtp_tls", "starttls")
    ctx = ssl.create_default_context()
    recipients = [a for _, a in getaddresses([to_addr, cc, bcc]) if a]
    if mode == "ssl" or port == 465:
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=30) as smtp:
            smtp.login(user, password)
            smtp.send_message(msg, from_addr=from_addr, to_addrs=recipients)
    else:
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            smtp.ehlo()
            if mode != "none":
                smtp.starttls(context=ctx)
                smtp.ehlo()
            smtp.login(user, password)
            smtp.send_message(msg, from_addr=from_addr, to_addrs=recipients)

    raw = msg.as_bytes()
    _append_sent(raw)
    local_id = _save_local(msg, "SENT", to_addr, cc, bcc, subject, body, matter_id, False, attachments or [])
    if reply_all_answered_id:
        set_flag(int(reply_all_answered_id), "answered", True)
    return {"ok": True, "id": local_id}


def _save_local(
    msg: EmailMessage,
    folder: str,
    to_addr: str,
    cc: str,
    bcc: str,
    subject: str,
    body: str,
    matter_id: Optional[int],
    draft: bool,
    attachments: list[dict[str, Any]],
) -> int:
    msgid = msg.get("Message-ID") or f"local-{db.utcnow()}"
    msg_id = db.execute(
        """INSERT INTO messages
           (folder, message_id, in_reply_to, references_header, from_addr, to_addr, cc_addr, bcc_addr,
            subject, sent_at, snippet, body_text, flags, matter_id, has_attachments, seen, draft, synced_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)""",
        (
            folder,
            msgid,
            msg.get("In-Reply-To") or "",
            msg.get("References") or "",
            msg.get("From") or "",
            to_addr,
            cc,
            bcc,
            subject,
            db.utcnow(),
            (body or "")[:280],
            body or "",
            json.dumps(["draft"] if draft else ["sent", "seen"]),
            matter_id,
            1 if attachments else 0,
            1 if draft else 0,
            db.utcnow(),
        ),
    )
    if attachments:
        folder_dir = MAIL_FILES / str(msg_id)
        folder_dir.mkdir(parents=True, exist_ok=True)
        import base64

        for att in attachments:
            data = att.get("bytes")
            if data is None and att.get("data"):
                data = base64.b64decode(att["data"])
            if not data:
                continue
            filename = Path(att.get("filename") or "attachment").name
            path = folder_dir / filename
            path.write_bytes(data)
            db.execute(
                """INSERT INTO attachments (message_id, filename, mime, size, saved_path)
                   VALUES (?, ?, ?, ?, ?)""",
                (msg_id, filename, att.get("mime") or "", len(data), str(path)),
            )
    db.fts_upsert(msg_id)
    harvest_addresses(to_addr, cc, bcc)
    return msg_id


def quote_original(msg: dict[str, Any], mode: str) -> dict[str, str]:
    subj = msg.get("subject") or ""
    body = msg.get("body_text") or ""
    if not body and msg.get("body_html"):
        body = re.sub(r"<[^>]+>", " ", msg["body_html"])
        body = re.sub(r"\s+", " ", body).strip()
    quoted = "\n".join("> " + line for line in (body or "").splitlines())
    stamp = f"On {msg.get('sent_at') or ''}, {msg.get('from_addr') or ''} wrote:"
    own = _own_address()
    if mode == "forward":
        subject = subj if subj.lower().startswith("fwd:") else f"Fwd: {subj}"
        to_addr = ""
        cc = ""
        body_out = f"\n\n---------- Forwarded message ----------\nFrom: {msg.get('from_addr')}\nDate: {msg.get('sent_at')}\nSubject: {subj}\nTo: {msg.get('to_addr')}\n\n{body}"
    else:
        subject = subj if subj.lower().startswith("re:") else f"Re: {subj}"
        to_addr = msg.get("reply_to") or msg.get("from_addr") or ""
        cc = ""
        if mode == "reply-all":
            addrs = []
            for header in (msg.get("to_addr"), msg.get("cc_addr")):
                for name, addr in getaddresses([header or ""]):
                    low = (addr or "").lower()
                    if low and low != own and low not in " ".join(addrs).lower():
                        addrs.append(formataddr((name, addr)) if name else addr)
            cc = ", ".join(addrs)
        body_out = f"\n\n{stamp}\n{quoted}"
    refs = " ".join(x for x in ((msg.get("references_header") or ""), (msg.get("message_id") or "")) if x)
    return {
        "to": to_addr,
        "cc": cc,
        "subject": subject,
        "body": body_out,
        "in_reply_to": msg.get("message_id") or "",
        "references": refs,
        "matter_id": msg.get("matter_id") or "",
    }


def save_attachments_to_matter(message_id: int, matter_id: int, doc_type: str = "correspondence") -> list[dict[str, Any]]:
    from .paths import MATTER_FILES

    kind = re.sub(r"[^a-z0-9_-]+", "", (doc_type or "correspondence").lower()) or "correspondence"
    atts = db.rows("SELECT * FROM attachments WHERE message_id = ?", (message_id,))
    dest = MATTER_FILES / str(matter_id) / kind
    dest.mkdir(parents=True, exist_ok=True)
    saved = []
    for att in atts:
        src = Path(att["saved_path"]) if att.get("saved_path") else None
        if not src or not src.exists():
            continue
        target = dest / att["filename"]
        n = 1
        while target.exists():
            target = dest / f"{target.stem}-{n}{target.suffix}"
            n += 1
        target.write_bytes(src.read_bytes())
        file_id = db.execute(
            """INSERT INTO files (matter_id, message_id, filename, path, source, doc_type, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (matter_id, message_id, target.name, str(target), "attachment", kind, db.utcnow()),
        )
        saved.append({"id": file_id, "filename": target.name, "path": str(target), "doc_type": kind})
    return saved
