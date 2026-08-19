"""Auto-label mail: client, eservice, court."""

from __future__ import annotations

import json
import re
from email.utils import getaddresses

from . import db

ESERVICE_HOSTS = (
    "myflcourtaccess.com",
    "e-portal",
    "eportal",
    "efiling",
    "e-filing",
    "flcourts.org",
    "courtmap",
)
ESERVICE_TEXT = re.compile(
    r"\b(e-?service|eservice|electronic service|certificate of service|"
    r"e-?filing portal|served via (the )?portal|courtesy copy of e-?service)\b",
    re.I,
)
COURT_HOSTS = (
    "flcourts.org",
    "flcourts1.gov",
    "jud6.org",
    "jud12.org",
    "jud13.org",
    "jud20.org",
    "20thcircuit",
    "cjis20",
    "leeclerk.org",
    "leclerk.org",
    "collierclerk.com",
    "hendryclerk.org",
    "charlotteclerk.com",
    "gladesclerk.com",
    "miami-dadeclerk.com",
    "cclerks.com",
    "myflcourtaccess.com",
)
COURT_TEXT = re.compile(
    r"\b(judicial assistant|\bja\b|hon(?:orable)?\.? |judge |general magistrate|"
    r"hearing officer|clerk of (the )?court|circuit court|family division|"
    r"case manager|court administration)\b",
    re.I,
)


def _addrs(*headers: str) -> list[str]:
    out = []
    for h in headers:
        for name, addr in getaddresses([h or ""]):
            if addr and "@" in addr:
                out.append((name or "", addr.lower()))
    return out


def _blob(msg: dict) -> str:
    return " ".join(str(msg.get(k) or "") for k in ("subject", "from_addr", "to_addr", "cc_addr", "snippet", "body_text"))


def _host(email_addr: str) -> str:
    return email_addr.split("@")[-1].lower() if "@" in email_addr else ""


def _client_emails() -> set[str]:
    rows = db.rows("SELECT client_email FROM matters WHERE ifnull(client_email,'') != ''")
    return {(r["client_email"] or "").strip().lower() for r in rows if r.get("client_email")}


def is_eservice(msg: dict) -> bool:
    text = _blob(msg)
    if ESERVICE_TEXT.search(text):
        return True
    low = text.lower()
    if any(h in low for h in ESERVICE_HOSTS):
        return True
    for name, addr in _addrs(msg.get("from_addr") or ""):
        if "eservice" in addr or "e-service" in addr or "noreply" in addr and "court" in addr:
            return True
        if any(h in _host(addr) for h in ("myflcourtaccess.com",)):
            return True
    return False


def is_court(msg: dict) -> bool:
    if COURT_TEXT.search(_blob(msg)):
        return True
    for name, addr in _addrs(msg.get("from_addr") or "", msg.get("to_addr") or "", msg.get("cc_addr") or ""):
        host = _host(addr)
        if any(h in host for h in COURT_HOSTS if h != "myflcourtaccess.com"):
            return True
        combined = f"{name} {addr}".lower()
        if any(w in combined for w in ("judicial assistant", " magistrate", "clerk of court", " hearing officer")):
            return True
        if re.search(r"\bja[._-]", addr) or addr.startswith("ja@"):
            return True
    return False


def is_client(msg: dict) -> bool:
    clients = _client_emails()
    if not clients:
        return False
    people = {addr for _, addr in _addrs(msg.get("from_addr") or "", msg.get("to_addr") or "", msg.get("cc_addr") or "")}
    return bool(people & clients)


def classify(msg: dict) -> list[str]:
    tags = []
    if is_eservice(msg):
        tags.append("eservice")
    if is_court(msg) and "eservice" not in tags:
        tags.append("court")
    elif is_court(msg) and "eservice" in tags:
        # portal mail from the court still counts as court personnel/court system
        tags.append("court")
    if is_client(msg):
        tags.append("client")
    return tags


def apply_labels(msg_id: int, msg: dict | None = None) -> list[str]:
    row = msg or db.one("SELECT * FROM messages WHERE id = ?", (msg_id,))
    if not row:
        return []
    tags = classify(row)
    db.execute("UPDATE messages SET labels = ? WHERE id = ?", (json.dumps(tags), msg_id))
    return tags


def parse_labels(raw) -> list[str]:
    if isinstance(raw, list):
        return raw
    if not raw:
        return []
    try:
        data = json.loads(raw)
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        return []


def filter_counts() -> dict[str, int]:
    rows = db.rows("SELECT labels, seen FROM messages WHERE deleted = 0")
    out = {"client": 0, "eservice": 0, "court": 0, "client_unseen": 0, "eservice_unseen": 0, "court_unseen": 0}
    for r in rows:
        tags = parse_labels(r.get("labels"))
        for key in ("client", "eservice", "court"):
            if key in tags:
                out[key] += 1
                if not r.get("seen"):
                    out[f"{key}_unseen"] += 1
    return out
