"""Pull hearing dates, deadlines, and service URLs out of mail."""

from __future__ import annotations

import re
from datetime import date, datetime
from typing import Any

MONTHS = (
    "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
)
MONTHS_ABBR = (
    "jan", "feb", "mar", "apr", "may", "jun",
    "jul", "aug", "sep", "sept", "oct", "nov", "dec",
)
MONTH_INDEX = {name: i + 1 for i, name in enumerate(MONTHS)}
for i, name in enumerate(MONTHS_ABBR):
    MONTH_INDEX.setdefault(name, (i if i < 9 else i - 1) + 1)
MONTH_INDEX["sept"] = 9

DATE_PATTERNS = [
    re.compile(
        r"\b("
        + "|".join(MONTHS + MONTHS_ABBR)
        + r")\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b",
        re.I,
    ),
    re.compile(
        r"\b(\d{1,2})(?:st|nd|rd|th)?\s+("
        + "|".join(MONTHS + MONTHS_ABBR)
        + r")\.?,?\s+(\d{4})\b",
        re.I,
    ),
    re.compile(r"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"),
    re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b"),
]

URL_RE = re.compile(r"https?://[^\s<>\"')\]]+", re.I)
HEARING_RE = re.compile(
    r"\b(hearing|deposition|mediation|case management|pretrial|pre-trial|"
    r"docket|trial|status conference|uniform motion calendar|umc|"
    r"return hearing|arraignment)\b",
    re.I,
)
DEADLINE_RE = re.compile(
    r"\b(respond by|due on|due date|deadline|must be filed|shall file|"
    r"within \d+ days|answers? due|response due)\b",
    re.I,
)
SERVICE_HINT = re.compile(
    r"(served with (the )?(petition|complaint|original process)|you are hereby (notified|commanded)|"
    r"summons|original process|file (an )?answer to the petition)",
    re.I,
)

SERVICE_HOSTS = (
    "myflcourtaccess.com",
    "flcourts.org",
    "clerk",
    "e-portal",
    "eportal",
    "sharefile",
    "onedrive",
    "dropbox.com",
    "box.com",
    "filevine",
    "clio",
    "proofserve",
    "provest",
    "serve-now",
    "servenow",
)


def _parse_month(name: str) -> int:
    return MONTH_INDEX.get(name.lower().rstrip("."), 0)


def _valid(year: int, month: int, day: int) -> date | None:
    try:
        return date(year, month, day)
    except ValueError:
        return None


def parse_dates(text: str) -> list[date]:
    found: list[date] = []
    seen: set[str] = set()
    for rx in DATE_PATTERNS:
        for m in rx.finditer(text or ""):
            g = m.groups()
            parsed = None
            if rx is DATE_PATTERNS[0]:
                parsed = _valid(int(g[2]), _parse_month(g[0]), int(g[1]))
            elif rx is DATE_PATTERNS[1]:
                parsed = _valid(int(g[2]), _parse_month(g[1]), int(g[0]))
            elif rx is DATE_PATTERNS[2]:
                parsed = _valid(int(g[2]), int(g[0]), int(g[1]))
            else:
                parsed = _valid(int(g[0]), int(g[1]), int(g[2]))
            if parsed and parsed.isoformat() not in seen:
                if 2000 <= parsed.year <= 2100:
                    seen.add(parsed.isoformat())
                    found.append(parsed)
    return found


def snippet_around(text: str, index: int, width: int = 90) -> str:
    start = max(0, index - width)
    end = min(len(text), index + width)
    chunk = re.sub(r"\s+", " ", text[start:end]).strip()
    return chunk


def extract(subject: str, body: str, sent_at: str | None = None) -> dict[str, Any]:
    text = f"{subject or ''}\n{body or ''}"
    events: list[dict[str, Any]] = []
    for d in parse_dates(text):
        idx = text.lower().find(d.strftime("%B").lower())
        if idx < 0:
            idx = 0
        window = snippet_around(text, max(idx, 0))
        kind = "deadline" if DEADLINE_RE.search(window) else "hearing" if HEARING_RE.search(window) else "date"
        title = f"{kind.title()} — {d.strftime('%b %d, %Y')}"
        if HEARING_RE.search(window):
            hm = HEARING_RE.search(window)
            title = f"{hm.group(1).title()} — {d.strftime('%b %d, %Y')}"
        events.append(
            {
                "type": "event",
                "event_type": kind if kind != "date" else "appointment",
                "title": title,
                "date": d.isoformat(),
                "context": window,
            }
        )

    urls: list[dict[str, Any]] = []
    seen_url: set[str] = set()
    for m in URL_RE.finditer(text):
        url = m.group(0).rstrip(".,;:)>\"'")
        if url in seen_url:
            continue
        seen_url.add(url)
        host = url.split("/")[2].lower() if "://" in url else ""
        service = any(h in host or h in url.lower() for h in SERVICE_HOSTS)
        urls.append(
            {
                "type": "url",
                "url": url,
                "service_likely": service or bool(SERVICE_HINT.search(snippet_around(text, m.start()))),
                "context": snippet_around(text, m.start()),
            }
        )

    deadlines: list[dict[str, Any]] = []
    if SERVICE_HINT.search(text):
        trigger = None
        if sent_at:
            try:
                trigger = datetime.fromisoformat(sent_at.replace("Z", "+00:00")).date().isoformat()
            except ValueError:
                trigger = sent_at[:10]
        deadlines.append(
            {
                "type": "deadline",
                "rule_id": "answer_20",
                "title": "If this is initial service — answer (20 days)",
                "trigger": trigger,
            }
        )
        deadlines.append(
            {
                "type": "deadline",
                "rule_id": "mandatory_disclosure_45",
                "title": "If this is initial service — mandatory disclosure (45 days)",
                "trigger": trigger,
            }
        )

    return {"events": events, "urls": urls, "deadlines": deadlines}
