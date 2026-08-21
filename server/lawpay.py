from __future__ import annotations

import json
import os
import secrets
import subprocess
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


API_BASE = "https://api.8am.com"
AUTHORIZE_URL = "https://secure.lawpay.com/oauth/authorize"
TOKEN_URL = f"{API_BASE}/oauth/token"
KEYCHAIN_SERVICE = "com.kenturnerlaw.praecipe.lawpay"

_states: dict[str, float] = {}
_state_lock = threading.Lock()


class LawPayError(RuntimeError):
    def __init__(self, message: str, status: int = 502, details: object | None = None):
        super().__init__(message)
        self.status = status
        self.details = details


@dataclass(frozen=True)
class Configuration:
    client_id: str
    client_secret: str
    redirect_uri: str


def _keychain_read(account: str) -> str:
    try:
        proc = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _keychain_write(account: str, value: str) -> None:
    try:
        proc = subprocess.run(
            ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", account, "-w", value],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.SubprocessError) as exc:
        raise LawPayError("The LawPay token could not be saved in the system credential store.", 500) from exc
    if proc.returncode != 0:
        raise LawPayError("The LawPay token could not be saved in the system credential store.", 500)


def _credential(environment_name: str, keychain_account: str) -> str:
    return os.environ.get(environment_name, "").strip() or _keychain_read(keychain_account)


def configuration() -> Configuration:
    client_id = _credential("PRAECIPE_LAWPAY_CLIENT_ID", "client-id")
    client_secret = _credential("PRAECIPE_LAWPAY_CLIENT_SECRET", "client-secret")
    redirect_uri = os.environ.get("PRAECIPE_LAWPAY_REDIRECT_URI", "").strip()
    if not redirect_uri:
        redirect_uri = "http://127.0.0.1:12090/oauth/lawpay"
    return Configuration(client_id, client_secret, redirect_uri)


def access_token() -> str:
    return _credential("PRAECIPE_LAWPAY_ACCESS_TOKEN", "access-token")


def new_authorization() -> str:
    cfg = configuration()
    if not cfg.client_id or not cfg.client_secret:
        raise LawPayError(
            "LawPay partner credentials are not configured. An approved LawPay partner OAuth application is required for invoice sync.",
            409,
        )
    state = secrets.token_urlsafe(32)
    now = time.time()
    with _state_lock:
        for old, created in list(_states.items()):
            if now - created > 600:
                _states.pop(old, None)
        _states[state] = now
    query = urlencode(
        {
            "redirect_uri": cfg.redirect_uri,
            "client_id": cfg.client_id,
            "scope": "payments",
            "response_type": "code",
            "state": state,
        }
    )
    return f"{AUTHORIZE_URL}?{query}"


def exchange_authorization_code(code: str, state: str) -> None:
    now = time.time()
    with _state_lock:
        created = _states.pop(state, None)
    if created is None or now - created > 600:
        raise LawPayError("The LawPay authorization expired or did not match this connection request.", 400)
    cfg = configuration()
    result = _request(
        "POST",
        TOKEN_URL,
        body={
            "client_id": cfg.client_id,
            "client_secret": cfg.client_secret,
            "grant_type": "authorization_code",
            "scope": "payments",
            "redirect_uri": cfg.redirect_uri,
            "code": code,
        },
        authenticated=False,
    )
    token = str(result.get("access_token") or "") if isinstance(result, dict) else ""
    if not token:
        raise LawPayError("LawPay did not return an access token.")
    _keychain_write("access-token", token)


def _request(
    method: str,
    url_or_path: str,
    *,
    body: dict[str, Any] | None = None,
    query: dict[str, str] | None = None,
    authenticated: bool = True,
) -> Any:
    url = url_or_path if url_or_path.startswith("https://") else f"{API_BASE}{url_or_path}"
    if query:
        url += ("&" if "?" in url else "?") + urlencode(query)
    headers = {"Accept": "application/json", "User-Agent": "Praecipe/1.0 LawPay integration"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if authenticated:
        token = access_token()
        if not token:
            raise LawPayError("LawPay is not connected. Connect the approved partner application first.", 409)
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(request, timeout=45) as response:
            raw = response.read()
            return json.loads(raw.decode("utf-8")) if raw else {}
    except HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            details: object = json.loads(raw)
        except json.JSONDecodeError:
            details = raw[:1000]
        if exc.code == 401:
            message = "LawPay authorization is no longer valid. Reconnect LawPay."
        elif exc.code == 404:
            message = "The requested LawPay record was not found."
        elif exc.code == 409:
            message = "LawPay rejected a duplicate or conflicting record. No second invoice was created."
        elif exc.code == 422:
            message = "LawPay rejected the invoice details. Check the client, bank account, rates, and time entries."
        else:
            message = f"LawPay returned HTTP {exc.code}."
        raise LawPayError(message, exc.code, details) from exc
    except URLError as exc:
        raise LawPayError("LawPay could not be reached. Check the network and try again.") from exc


def bank_accounts() -> list[dict[str, Any]]:
    result = _request("GET", "/bank-accounts")
    if not isinstance(result, list):
        raise LawPayError("LawPay returned an invalid bank-account response.")
    return result


def status(selected_bank_account_id: str = "") -> dict[str, Any]:
    cfg = configuration()
    token = access_token()
    out: dict[str, Any] = {
        "configured": bool(cfg.client_id and cfg.client_secret),
        "connected": bool(token),
        "redirect_uri": cfg.redirect_uri,
        "selected_bank_account_id": selected_bank_account_id,
        "bank_accounts": [],
    }
    if token:
        accounts = bank_accounts()
        out["bank_accounts"] = [
            {
                "id": item.get("id"),
                "name": item.get("name") or item.get("bank_name") or "LawPay account",
                "bank_name": item.get("bank_name") or "",
                "trust": bool(item.get("trust")),
                "currency": item.get("currency") or "USD",
                "test_mode": bool(item.get("test_mode")),
                "masked_account": item.get("account_id") or "",
            }
            for item in accounts
        ]
    return out


def _contact(payload: dict[str, Any]) -> dict[str, Any]:
    source_id = f"praecipe:matter:{payload['matter_external_id']}"
    try:
        found = _request("GET", "/contacts/source-id", query={"id": source_id})
        if isinstance(found, dict) and found.get("id"):
            return found
    except LawPayError as exc:
        if exc.status != 404:
            raise

    full_name = str(payload.get("client_name") or "").strip()
    pieces = full_name.split(None, 1)
    first_name = pieces[0] if pieces else ""
    last_name = pieces[1] if len(pieces) > 1 else ""
    created = _request(
        "POST",
        "/contacts",
        body={
            "first_name": first_name,
            "last_name": last_name,
            "source_id": source_id,
            "email_addresses": [{"address": payload["client_email"]}],
            "tags": ["default"],
            "type": "person",
        },
    )
    if not isinstance(created, dict) or not created.get("id"):
        raise LawPayError("LawPay created the contact but did not return its identifier.")
    return created


def create_invoice(payload: dict[str, Any], default_bank_account_id: str = "") -> dict[str, Any]:
    client_email = str(payload.get("client_email") or "").strip().lower()
    if "@" not in client_email:
        raise LawPayError("The matter needs a valid client email before a LawPay invoice can be sent.", 400)
    matter_external_id = str(payload.get("matter_external_id") or "").strip()
    source_id = str(payload.get("source_id") or "").strip()
    entries = payload.get("entries")
    if not matter_external_id or not source_id or not isinstance(entries, list) or not entries:
        raise LawPayError("The invoice is missing its matter, unique source ID, or time entries.", 400)
    if not source_id.startswith("praecipe:invoice:"):
        raise LawPayError("The invoice source ID is invalid.", 400)

    bank_account_id = str(payload.get("bank_account_id") or default_bank_account_id or "").strip()
    if not bank_account_id.startswith("bank_"):
        raise LawPayError("Choose a LawPay operating or trust bank account before creating an invoice.", 400)

    line_items: list[dict[str, str]] = []
    for entry in entries:
        cents = int(entry.get("fee_cents") or 0)
        if cents <= 0:
            raise LawPayError("Every LawPay invoice entry must have a positive fee. Check the matter rate and minutes.", 400)
        description = str(entry.get("description") or entry.get("activity") or "Legal services").strip()
        line_items.append(
            {
                "description": description[:500],
                "rate_per_quantity": str(cents),
                "quantity": "1",
                "rate_type": "units",
            }
        )

    contact = _contact({**payload, "client_email": client_email, "matter_external_id": matter_external_id})
    invoice_body: dict[str, Any] = {
        "contact_id": contact["id"],
        "bank_account_id": bank_account_id,
        "invoice_date": str(payload.get("invoice_date") or datetime.now(timezone.utc).date().isoformat()),
        "currency": "USD",
        "reference": str(payload.get("reference") or "Praecipe legal services")[:100],
        "source_id": source_id,
        "line_items": line_items,
        "test_mode": bool(payload.get("test_mode", False)),
    }
    if payload.get("send_email", True):
        invoice_body["invoice_messages"] = [
            {
                "email_addresses": [client_email],
                "subject": str(payload.get("email_subject") or "Your legal services invoice")[:200],
                "message": str(
                    payload.get("email_message")
                    or "For your convenience, our firm accepts payment through LawPay. Use the secure link below to review and pay this invoice."
                )[:2000],
            }
        ]

    invoice = _request("POST", "/invoices", body=invoice_body)
    if not isinstance(invoice, dict) or not invoice.get("id"):
        raise LawPayError("LawPay did not return an invoice identifier.")
    return {
        "ok": True,
        "invoice_id": invoice["id"],
        "invoice_number": invoice.get("invoice_number") or invoice.get("number") or "",
        "status": invoice.get("status") or "created",
        "contact_id": contact["id"],
        "source_id": source_id,
        "sent": bool(payload.get("send_email", True)),
    }
