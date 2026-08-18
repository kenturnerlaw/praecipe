"""Florida Family Law Rules of Procedure — deadline computation.

Computation follows Fla. Fam. L. R. P. 12.090, which applies
Fla. R. Gen. Prac. & Jud. Admin. 2.514.

This is a practice aid, not legal advice. Confirm against the current
rules, any statute, the judge's order, and local administrative practice.
Statutory periods do not receive the extra 5 days for mail/e-mail service.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Optional


# Rule 2.514(a)(6) enumerated legal holidays (calendar date of the holiday).
def _nth_weekday(year: int, month: int, weekday: int, n: int) -> date:
    d = date(year, month, 1)
    while d.weekday() != weekday:
        d += timedelta(days=1)
    return d + timedelta(weeks=n - 1)


def _last_weekday(year: int, month: int, weekday: int) -> date:
    if month == 12:
        d = date(year, 12, 31)
    else:
        d = date(year, month + 1, 1) - timedelta(days=1)
    while d.weekday() != weekday:
        d -= timedelta(days=1)
    return d


def legal_holidays(year: int) -> set[date]:
    return {
        date(year, 1, 1),  # New Year's Day
        _nth_weekday(year, 1, 0, 3),  # MLK Jr. Day (3rd Monday)
        _nth_weekday(year, 2, 0, 3),  # Washington's Birthday
        _last_weekday(year, 5, 0),  # Memorial Day
        date(year, 7, 4),  # Independence Day
        _nth_weekday(year, 9, 0, 1),  # Labor Day
        _nth_weekday(year, 10, 0, 2),  # Columbus Day
        date(year, 11, 11),  # Veterans Day
        _nth_weekday(year, 11, 3, 4),  # Thanksgiving
        date(year, 12, 25),  # Christmas
    }


def is_legal_holiday(d: date) -> bool:
    return d in legal_holidays(d.year) or d in legal_holidays(d.year - 1) or d in legal_holidays(d.year + 1)


def is_non_business(d: date) -> bool:
    return d.weekday() >= 5 or is_legal_holiday(d)


def roll_forward(d: date) -> date:
    while is_non_business(d):
        d += timedelta(days=1)
    return d


def add_days_2_514(trigger: date, days: int) -> date:
    """Exclude the trigger day, count every calendar day, roll last day."""
    if days == 0:
        return roll_forward(trigger)
    step = 1 if days > 0 else -1
    remaining = abs(days)
    current = trigger
    while remaining > 0:
        current += timedelta(days=step)
        remaining -= 1
    if days > 0:
        return roll_forward(current)
    while is_non_business(current):
        current -= timedelta(days=1)
    return current


def add_five_after_service(expiry: date) -> date:
    """Rule 2.514(b): 5 days added after the period would otherwise expire."""
    d = expiry + timedelta(days=5)
    return roll_forward(d)


def add_business_days(start: date, n: int, *, before: bool = False) -> date:
    step = -1 if before else 1
    remaining = abs(n)
    current = start
    while remaining > 0:
        current += timedelta(days=step)
        if not is_non_business(current):
            remaining -= 1
    return current


CATALOG = [
    {
        "id": "answer_20",
        "title": "Answer / responsive pleading",
        "rule": "Fla. Fam. L. R. P. 12.140; Fla. R. Civ. P. 1.140(a)",
        "days": 20,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date of service of process",
        "note": "Twenty days after service of original process and the initial pleading, unless a statute or order shortens or enlarges the time.",
    },
    {
        "id": "counter_20",
        "title": "Answer to counterpetition",
        "rule": "Fla. Fam. L. R. P. 12.140; Fla. R. Civ. P. 1.140(a)",
        "days": 20,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date counterpetition was served",
        "note": "Same responsive period as an initial pleading.",
    },
    {
        "id": "mandatory_disclosure_45",
        "title": "Mandatory disclosure — initial",
        "rule": "Fla. Fam. L. R. P. 12.285(b)",
        "days": 45,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date initial pleading was served on respondent",
        "note": "Each party files and serves a financial affidavit and the 12.285(c) documents within 45 days of service of the initial pleading on the respondent.",
    },
    {
        "id": "temp_financial_2bd",
        "title": "Temporary financial relief disclosures",
        "rule": "Fla. Fam. L. R. P. 12.285(d)",
        "days": 2,
        "direction": "before",
        "unit": "business_days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Temporary financial hearing date",
        "note": "Serve the financial affidavit and 12.285(c) disclosures at least 2 business days before the hearing if not already provided.",
    },
    {
        "id": "supplement_24h",
        "title": "Supplemental disclosure before hearing",
        "rule": "Fla. Fam. L. R. P. 12.285",
        "days": 1,
        "direction": "before",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Hearing date",
        "note": "Continuing duty to supplement. Serve supplemental disclosure as soon as possible and in no event later than 24 hours before the applicable hearing (treat as the prior calendar day; verify the current subdivision text).",
    },
    {
        "id": "rogs_30",
        "title": "Answers to interrogatories",
        "rule": "Fla. Fam. L. R. P. 12.340; Fla. R. Civ. P. 1.340",
        "days": 30,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date interrogatories were served",
        "note": "Serve answers (and objections) within 30 days after service of the interrogatories.",
    },
    {
        "id": "rtp_30",
        "title": "Response to request to produce",
        "rule": "Fla. Fam. L. R. P. 12.350; Fla. R. Civ. P. 1.350",
        "days": 30,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date request to produce was served",
        "note": "Written response within 30 days after service of the request.",
    },
    {
        "id": "rfa_30",
        "title": "Response to requests for admission",
        "rule": "Fla. Fam. L. R. P. 12.370; Fla. R. Civ. P. 1.370",
        "days": 30,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date requests for admission were served",
        "note": "A matter is admitted unless a written answer or objection is served within 30 days after service of the request.",
    },
    {
        "id": "exam_30",
        "title": "Response / objection to examination of persons",
        "rule": "Fla. Fam. L. R. P. 12.360; Fla. R. Civ. P. 1.360",
        "days": 30,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date request for examination was served",
        "note": "Serve a response stating compliance or objections within 30 days after service of the request.",
    },
    {
        "id": "magistrate_obj_10",
        "title": "Objection to referral to general magistrate",
        "rule": "Fla. Fam. L. R. P. 12.490",
        "days": 10,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date order of referral was served",
        "note": "File an objection to the referral within 10 days of service of the order of referral.",
    },
    {
        "id": "magistrate_ex_10",
        "title": "Exceptions to general magistrate report",
        "rule": "Fla. Fam. L. R. P. 12.490",
        "days": 10,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date magistrate report was served",
        "note": "File exceptions within 10 days from service of the report and recommendations.",
    },
    {
        "id": "csho_ex_10",
        "title": "Exceptions to child support hearing officer",
        "rule": "Fla. Fam. L. R. P. 12.491",
        "days": 10,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Date recommended order was received / served",
        "note": "File exceptions to the recommended order within 10 days of receipt.",
    },
    {
        "id": "rehearing_15",
        "title": "Motion for rehearing",
        "rule": "Fla. Fam. L. R. P. 12.530; Fla. R. Civ. P. 1.530",
        "days": 15,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Date judgment / order was filed",
        "note": "Serve a motion for rehearing not later than 15 days after the date of filing of the judgment or within the time allowed for taking an appeal, as applicable. Extra 5 days for mail generally does not stretch this filing period.",
    },
    {
        "id": "default_check_20",
        "title": "Possible default (no response)",
        "rule": "Fla. Fam. L. R. P. 12.500; Fla. R. Civ. P. 1.500",
        "days": 20,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Date of service of process",
        "note": "Calendar the date after which a default may be sought if no paper is served. Confirm military affidavit and clerk practice before filing.",
    },
    {
        "id": "injunction_return",
        "title": "Injunction for protection — return hearing",
        "rule": "Fla. Fam. L. R. P. 12.610; § 741.30 / 784.046, Fla. Stat.",
        "days": 15,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": True,
        "trigger_label": "Date temporary injunction issued / filed",
        "note": "Return hearing is typically set within 15 days. This is a statutory / rule hearing setting — use the actual notice, not this estimate, when a date is already on the order.",
    },
    {
        "id": "pfs_90",
        "title": "Proposal for settlement — earliest serve",
        "rule": "Fla. R. Civ. P. 1.442",
        "days": 90,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Date of service of process",
        "note": "A proposal may not be served sooner than 90 days after service of process. Also cannot be served later than 45 days before trial.",
    },
    {
        "id": "pfs_accept_30",
        "title": "Proposal for settlement — time to accept",
        "rule": "Fla. R. Civ. P. 1.442",
        "days": 30,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Date proposal for settlement was served",
        "note": "A proposal is deemed rejected unless accepted in writing within 30 days after service (or such other time as the parties agree or the court orders).",
    },
    {
        "id": "pfs_45_before_trial",
        "title": "Proposal for settlement — latest serve",
        "rule": "Fla. R. Civ. P. 1.442",
        "days": 45,
        "direction": "before",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Trial date",
        "note": "Do not serve a proposal later than 45 days before the trial date.",
    },
    {
        "id": "appeal_final_30",
        "title": "Appeal of final order",
        "rule": "Fla. R. App. P. 9.110(b)",
        "days": 30,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": True,
        "trigger_label": "Date order / judgment was rendered (filed)",
        "note": "Notice of appeal generally must be filed within 30 days of rendition. No extra 5 days. Confirm rendition and any timely rehearing motion.",
    },
    {
        "id": "appeal_nonfinal_30",
        "title": "Appeal of nonfinal order",
        "rule": "Fla. R. App. P. 9.130",
        "days": 30,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": True,
        "trigger_label": "Date nonfinal order was rendered",
        "note": "Thirty days from rendition of an appealable nonfinal order. No extra 5 days.",
    },
    {
        "id": "relocation_notice_60",
        "title": "Relocation — notice before moving",
        "rule": "§ 61.13001, Fla. Stat.",
        "days": 60,
        "direction": "before",
        "unit": "days",
        "service_extra": False,
        "statutory": True,
        "trigger_label": "Proposed relocation date",
        "note": "Unless the parties agree or the court orders otherwise, a parent must give notice of a proposed relocation (typically 60 days before). Use the statute and form 12.950.",
    },
    {
        "id": "relocation_obj_20",
        "title": "Relocation — objection",
        "rule": "§ 61.13001, Fla. Stat.; Form 12.950",
        "days": 20,
        "direction": "after",
        "unit": "days",
        "service_extra": False,
        "statutory": True,
        "trigger_label": "Date notice of intent to relocate was served",
        "note": "File and serve a written objection within the statutory window stated on the notice (commonly 20 days). Read the notice and current statute; do not rely solely on this default.",
    },
    {
        "id": "notice_hearing_7",
        "title": "Notice of hearing (reasonable notice)",
        "rule": "Fla. Fam. L. R. P. 12.090; 12.440; local practice",
        "days": 7,
        "direction": "before",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Hearing date",
        "note": "The rules require reasonable notice. Many family divisions expect at least 5–7 days unless the court shortens time. Check the division’s administrative order.",
    },
    {
        "id": "discovery_cutoff_30",
        "title": "Discovery cutoff (if no order)",
        "rule": "Fla. Fam. L. R. P. 12.200 / trial order",
        "days": 30,
        "direction": "before",
        "unit": "days",
        "service_extra": False,
        "statutory": False,
        "trigger_label": "Trial date",
        "note": "Use the case-management or trial order when one exists. This 30-day placeholder is only a docket reminder.",
    },
    {
        "id": "custom",
        "title": "Custom period (Rule 12.090 / 2.514 counting)",
        "rule": "Fla. Fam. L. R. P. 12.090; Fla. R. Gen. Prac. & Jud. Admin. 2.514",
        "days": None,
        "direction": "after",
        "unit": "days",
        "service_extra": True,
        "statutory": False,
        "trigger_label": "Trigger date",
        "note": "Enter any number of days. Counting excludes the trigger day, includes intermediate weekends, and rolls the last day if it is a Saturday, Sunday, or legal holiday.",
    },
]


def catalog_item(rule_id: str) -> Optional[dict]:
    for item in CATALOG:
        if item["id"] == rule_id:
            return item
    return None


def compute(
    rule_id: str,
    trigger: date,
    *,
    days: Optional[int] = None,
    service_mail_or_email: bool = False,
    direction: Optional[str] = None,
    unit: Optional[str] = None,
    statutory: Optional[bool] = None,
) -> dict:
    item = catalog_item(rule_id) or {
        "id": rule_id,
        "title": "Custom",
        "rule": "Fla. Fam. L. R. P. 12.090; Rule 2.514",
        "days": days,
        "direction": direction or "after",
        "unit": unit or "days",
        "service_extra": True,
        "statutory": False,
        "note": "",
    }
    n = days if days is not None else item.get("days")
    if n is None:
        raise ValueError("days is required")
    direction = direction or item.get("direction") or "after"
    unit = unit or item.get("unit") or "days"
    statutory = item.get("statutory", False) if statutory is None else statutory
    extra_ok = bool(item.get("service_extra")) and not statutory and service_mail_or_email

    if unit == "business_days":
        due = add_business_days(trigger, n, before=(direction == "before"))
    elif direction == "before":
        due = add_days_2_514(trigger, -n)
    else:
        due = add_days_2_514(trigger, n)

    extra_applied = False
    if extra_ok and direction == "after" and unit == "days":
        due = add_five_after_service(due)
        extra_applied = True

    return {
        "rule_id": item["id"],
        "title": item["title"],
        "rule": item["rule"],
        "trigger": trigger.isoformat(),
        "days": n,
        "direction": direction,
        "unit": unit,
        "due": due.isoformat(),
        "service_extra_applied": extra_applied,
        "statutory": statutory,
        "weekday": due.strftime("%A"),
        "note": item.get("note") or "",
    }
