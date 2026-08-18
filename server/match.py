"""Rank matters for a message. Confidence is 0–100, not a guarantee."""

from __future__ import annotations

import re
from email.utils import getaddresses

from . import db

STOP = {
    "the", "and", "for", "vs", "v", "aka", "nka", "fka", "estate", "minor", "child",
    "unknown", "intake", "unassigned", "mail", "petitioner", "respondent",
}

CASE_NO_RE = re.compile(
    r"\b(\d{2,4}[- ]?DR[- ]?\d{1,6}|\d{2}DR\d{3,6}|\d{4}[A-Z]{2,4}\d{3,8})\b",
    re.I,
)

DOC_TYPES = [
    ("correspondence", "Correspondence"),
    ("pleading", "Pleading"),
    ("notice", "Notice / hearing"),
    ("discovery", "Discovery"),
    ("financial", "Financial / disclosure"),
    ("order", "Order / judgment"),
    ("service", "Service / summons"),
    ("other", "Other"),
]


def _emails(*headers: str) -> set[str]:
    out = set()
    for h in headers:
        for _, addr in getaddresses([h or ""]):
            if addr and "@" in addr:
                out.add(addr.lower())
    return out


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def _last_name(party: str) -> str:
    if not party:
        return ""
    # "Doe, Jane" or "Jane Doe"
    if "," in party:
        return _norm(party.split(",")[0]).split()[0] if party.split(",")[0].strip() else ""
    parts = [p for p in _norm(party).split() if p not in STOP and len(p) > 2]
    return parts[-1] if parts else ""


def _text_blob(msg: dict) -> str:
    return " ".join(
        str(msg.get(k) or "")
        for k in ("subject", "from_addr", "to_addr", "cc_addr", "snippet", "body_text")
    )


def guess_doc_type(msg: dict, filenames: list[str] | None = None) -> str:
    text = _norm(_text_blob(msg) + " " + " ".join(filenames or []))
    rules = (
        ("service", ("summons", "return of service", "proof of service", "served", "process server")),
        ("financial", ("financial affidavit", "mandatory disclosure", "tax return", "pay stub", "w-2", "w2")),
        ("discovery", ("interrogator", "request to produce", "request for admission", "deposition", "duces tecum")),
        ("order", ("order", "judgment", "fiat", "decree")),
        ("notice", ("notice of hearing", "notice of trial", "notice of mediation", "notice of taking")),
        ("pleading", ("petition", "motion", "response", "answer", "counterpetition")),
    )
    for kind, needles in rules:
        if any(n in text for n in needles):
            return kind
    if filenames:
        return "pleading"
    return "correspondence"


def match_matters(msg: dict, limit: int = 5) -> list[dict]:
    blob = _norm(_text_blob(msg))
    raw = _text_blob(msg)
    addrs = _emails(msg.get("from_addr") or "", msg.get("to_addr") or "", msg.get("cc_addr") or "")
    case_hits = {m.group(1).upper().replace(" ", "") for m in CASE_NO_RE.finditer(raw)}
    from_email = next(iter(_emails(msg.get("from_addr") or "")), "")

    prior: dict[int, int] = {}
    if from_email:
        for row in db.rows(
            """SELECT matter_id, COUNT(*) AS n FROM messages
               WHERE matter_id IS NOT NULL AND lower(from_addr) LIKE ?
               GROUP BY matter_id""",
            (f"%{from_email}%",),
        ):
            if row["matter_id"]:
                prior[int(row["matter_id"])] = int(row["n"])

    contact_matters = {}
    if addrs:
        placeholders = ",".join("?" * len(addrs))
        for row in db.rows(
            f"SELECT matter_id, email FROM contacts WHERE matter_id IS NOT NULL AND lower(email) IN ({placeholders})",
            tuple(addrs),
        ):
            contact_matters[int(row["matter_id"])] = row["email"]

    scored = []
    for m in db.rows("SELECT * FROM matters WHERE status != 'closed'"):
        reasons = []
        score = 0
        case_no = (m.get("case_no") or "").strip()
        if case_no and case_no.upper() != "INTAKE":
            compact = re.sub(r"[\s-]", "", case_no).upper()
            if compact and compact in re.sub(r"[\s-]", "", raw).upper():
                score += 55
                reasons.append(f"case number {case_no}")
            elif any(compact in h or h in compact for h in case_hits if len(h) >= 5):
                score += 50
                reasons.append(f"case number {case_no}")

        pet, resp = _last_name(m.get("petitioner") or ""), _last_name(m.get("respondent") or "")
        name_hits = 0
        for ln, label in ((pet, "petitioner"), (resp, "respondent")):
            if ln and len(ln) >= 3 and re.search(rf"\b{re.escape(ln)}\b", blob):
                name_hits += 1
                reasons.append(f"{label} “{ln}”")
        if name_hits == 2:
            score += 40
        elif name_hits == 1:
            score += 18

        style = _norm(m.get("style") or "")
        if style and len(style) > 8 and style in blob:
            score += 20
            reasons.append("caption")

        oc = _norm(m.get("opposing_counsel") or "")
        if oc and len(oc) > 4 and oc in blob:
            score += 15
            reasons.append("opposing counsel")

        mid = int(m["id"])
        if mid in prior:
            bump = min(30, 12 + prior[mid] * 3)
            score += bump
            reasons.append(f"prior mail from this sender ({prior[mid]})")
        if mid in contact_matters:
            score += 25
            reasons.append(f"contact {contact_matters[mid]}")

        client = (m.get("client_email") or "").lower()
        if client and client in addrs:
            score += 20
            reasons.append("client on the thread")

        if (m.get("case_no") or "").upper() == "INTAKE":
            score = min(score, 12)
            if not reasons:
                reasons.append("intake fallback")

        score = max(0, min(99, score))
        if score <= 0 and (m.get("case_no") or "").upper() == "INTAKE":
            score = 8
            reasons.append("intake fallback")
        if score <= 0:
            continue
        scored.append(
            {
                "matter_id": mid,
                "case_no": m.get("case_no") or "",
                "style": m.get("style") or "",
                "client_email": m.get("client_email") or "",
                "client_name": m.get("client_name") or "",
                "confidence": score,
                "reasons": reasons,
                "label": (f"{m.get('case_no')} — {m.get('style')}" if m.get("case_no") else m.get("style") or f"Matter {mid}"),
            }
        )
    scored.sort(key=lambda x: (-x["confidence"], x["label"]))
    return scored[:limit]
