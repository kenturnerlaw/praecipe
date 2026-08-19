from __future__ import annotations

import base64
import hashlib
import json
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Optional

from . import db

REDIRECT_BASE = "http://127.0.0.1:12090"
MS_TENANT = "organizations"
MS_AUTHORITY = f"https://login.microsoftonline.com/{MS_TENANT}/oauth2/v2.0"

PROVIDERS: dict[str, dict[str, Any]] = {
    "gmail": {
        "label": "Google",
        "imap_host": "imap.gmail.com",
        "imap_port": "993",
        "smtp_host": "smtp.gmail.com",
        "smtp_port": "465",
        "smtp_tls": "ssl",
        "imap_user_mode": "email",
        "auth_url": "https://accounts.google.com/o/oauth2/v2/auth",
        "token_url": "https://oauth2.googleapis.com/token",
        "userinfo_url": "https://www.googleapis.com/oauth2/v2/userinfo",
        "scopes": "https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email",
        "redirect_path": "/oauth/google",
        "client_id_key": "google_oauth_client_id",
        "client_secret_key": "google_oauth_client_secret",
        "app_password_url": "https://myaccount.google.com/apppasswords",
        "help_url": "https://myaccount.google.com/signinoptions/two-step-verification",
        "imap_help_url": "https://mail.google.com/mail/u/0/#settings/fwdandpop",
    },
    "microsoft": {
        "label": "Microsoft 365",
        "imap_host": "outlook.office365.com",
        "imap_port": "993",
        "smtp_host": "smtp.office365.com",
        "smtp_port": "587",
        "smtp_tls": "starttls",
        "imap_user_mode": "email",
        "auth_url": f"{MS_AUTHORITY}/authorize",
        "token_url": f"{MS_AUTHORITY}/token",
        "device_code_url": f"{MS_AUTHORITY}/devicecode",
        "scopes": "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send",
        "redirect_path": "/oauth/microsoft",
        "client_id_key": "microsoft_oauth_client_id",
        "client_secret_key": "microsoft_oauth_client_secret",
        "help_url": "https://admin.microsoft.com",
        "azure_url": "https://aka.ms/AppRegistrations",
        "device_url": "https://microsoft.com/devicelogin",
    },
    "icloud": {
        "label": "iCloud",
        "imap_host": "imap.mail.me.com",
        "imap_port": "993",
        "smtp_host": "smtp.mail.me.com",
        "smtp_port": "587",
        "smtp_tls": "starttls",
        "imap_user_mode": "local_or_email",
        "app_password_url": "https://account.apple.com/account/manage/section/security",
        "help_url": "https://support.apple.com/102654",
        "mail_settings_url": "https://support.apple.com/102525",
    },
}

_pending: dict[str, dict[str, Any]] = {}
_lock = threading.Lock()


def provider_public(name: str) -> dict[str, Any]:
    spec = PROVIDERS[name]
    return {
        "id": name,
        "label": spec["label"],
        "imap_host": spec["imap_host"],
        "imap_port": spec["imap_port"],
        "smtp_host": spec["smtp_host"],
        "smtp_port": spec["smtp_port"],
        "smtp_tls": spec["smtp_tls"],
        "oauth": bool(spec.get("auth_url")),
        "oauth_ready": bool(spec.get("auth_url") and db.setting(spec.get("client_id_key") or "")),
        "redirect_uri": f"{REDIRECT_BASE}{spec['redirect_path']}" if spec.get("redirect_path") else "",
        "app_password_url": spec.get("app_password_url") or "",
        "help_url": spec.get("help_url") or "",
        "imap_help_url": spec.get("imap_help_url") or "",
        "azure_url": spec.get("azure_url") or "",
        "mail_settings_url": spec.get("mail_settings_url") or "",
    }


def list_providers() -> list[dict[str, Any]]:
    return [provider_public(name) for name in ("gmail", "microsoft", "icloud")]


def preset(name: str) -> dict[str, str]:
    spec = PROVIDERS[name]
    return {
        "imap_host": spec["imap_host"],
        "imap_port": spec["imap_port"],
        "smtp_host": spec["smtp_host"],
        "smtp_port": spec["smtp_port"],
        "smtp_tls": spec["smtp_tls"],
    }


def imap_user_for(provider: str, email: str) -> str:
    email = (email or "").strip()
    spec = PROVIDERS.get(provider) or {}
    if spec.get("imap_user_mode") == "local_or_email" and "@" in email:
        return email
    return email


def _pkce() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def _post_form(url: str, data: dict[str, str]) -> dict[str, Any]:
    body = urllib.parse.urlencode(data).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = {}
        if parsed.get("error") in ("authorization_pending", "slow_down"):
            return parsed
        raise RuntimeError(parsed.get("error_description") or parsed.get("error") or raw or str(exc)) from exc
    return json.loads(raw) if raw else {}


def _get_json(url: str, token: str) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def start_oauth(provider: str, email: str = "", display_name: str = "") -> dict[str, Any]:
    spec = PROVIDERS.get(provider)
    if not spec or not spec.get("auth_url"):
        raise ValueError("This provider does not support browser sign-in. Use an app password.")
    client_id = db.setting(spec["client_id_key"])
    if not client_id:
        raise ValueError(f"Add the {spec['label']} client ID in Accounts first, then sign in.")
    verifier, challenge = _pkce()
    state = secrets.token_urlsafe(24)
    redirect = f"{REDIRECT_BASE}{spec['redirect_path']}"
    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect,
        "scope": spec["scopes"],
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if provider == "microsoft":
        params["prompt"] = "select_account"
    if provider == "gmail":
        params["access_type"] = "offline"
        params["prompt"] = "consent"
        params["include_granted_scopes"] = "true"
    if email:
        params["login_hint"] = email
    url = spec["auth_url"] + "?" + urllib.parse.urlencode(params)
    with _lock:
        _pending[state] = {
            "provider": provider,
            "email": (email or "").strip(),
            "display_name": (display_name or "").strip(),
            "verifier": verifier,
            "created": time.time(),
            "status": "pending",
        }
    return {"ok": True, "url": url, "state": state}


def pending_status(state: str) -> dict[str, Any]:
    with _lock:
        row = dict(_pending.get(state) or {})
    if not row:
        return {"status": "unknown"}
    return {"status": row.get("status") or "pending", "error": row.get("error") or "", "account_id": row.get("account_id")}


def email_from_token(token: str) -> str:
    try:
        parts = (token or "").split(".")
        if len(parts) < 2:
            return ""
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
        return str(data.get("upn") or data.get("unique_name") or data.get("preferred_username") or data.get("email") or "")
    except Exception:
        return ""


def _account_from_tokens(provider: str, tokens: dict[str, Any], pending: dict[str, Any]) -> dict[str, Any]:
    if tokens.get("error"):
        raise RuntimeError(tokens.get("error_description") or tokens["error"])
    access = tokens.get("access_token") or ""
    refresh = tokens.get("refresh_token") or ""
    expires = int(time.time()) + int(tokens.get("expires_in") or 3600) - 60
    email = (pending.get("email") or "").strip() or email_from_token(access)
    spec = PROVIDERS[provider]
    if provider == "gmail" and access:
        try:
            info = _get_json(spec["userinfo_url"], access)
            email = info.get("email") or email
        except Exception:
            pass
    if not email:
        raise ValueError("Could not read the mailbox address. Enter the Microsoft email and sign in again.")
    if not refresh:
        raise ValueError(
            f"{spec['label']} did not return a refresh token. Remove Praecipe from the account’s connected apps and sign in again."
        )
    hosts = preset(provider)
    saved = db.upsert_account(
        {
            "provider": provider,
            "email": email,
            "display_name": pending.get("display_name") or "",
            "imap_host": hosts["imap_host"],
            "imap_port": hosts["imap_port"],
            "imap_user": email,
            "smtp_host": hosts["smtp_host"],
            "smtp_port": hosts["smtp_port"],
            "smtp_user": email,
            "smtp_tls": hosts["smtp_tls"],
            "auth_type": "oauth",
            "password": "",
            "oauth_refresh_token": refresh,
            "oauth_access_token": access,
            "oauth_expires_at": expires,
            "enabled": 1,
        }
    )
    with _lock:
        pending["status"] = "ok"
        pending["account_id"] = saved["id"]
    return saved


def finish_oauth(provider: str, code: str, state: str) -> dict[str, Any]:
    spec = PROVIDERS[provider]
    with _lock:
        pending = _pending.get(state)
    if not pending or pending.get("provider") != provider:
        raise ValueError("Sign-in expired. Start again from Accounts.")
    if time.time() - float(pending.get("created") or 0) > 900:
        raise ValueError("Sign-in expired. Start again from Accounts.")
    client_id = db.setting(spec["client_id_key"])
    secret = db.setting(spec.get("client_secret_key") or "")
    data = {
        "client_id": client_id,
        "code": code,
        "code_verifier": pending["verifier"],
        "grant_type": "authorization_code",
        "redirect_uri": f"{REDIRECT_BASE}{spec['redirect_path']}",
    }
    if secret:
        data["client_secret"] = secret
    tokens = _post_form(spec["token_url"], data)
    return _account_from_tokens(provider, tokens, pending)


def start_microsoft_device(email: str = "", display_name: str = "") -> dict[str, Any]:
    spec = PROVIDERS["microsoft"]
    client_id = (db.setting(spec["client_id_key"]) or "").strip()
    if not client_id:
        raise ValueError("Paste the Application (client) ID from Microsoft, then Sign in.")
    out = _post_form(
        spec["device_code_url"],
        {"client_id": client_id, "scope": spec["scopes"]},
    )
    if out.get("error"):
        raise RuntimeError(out.get("error_description") or out["error"])
    state = secrets.token_urlsafe(24)
    pending = {
        "provider": "microsoft",
        "email": (email or "").strip(),
        "display_name": (display_name or "").strip(),
        "device_code": out["device_code"],
        "created": time.time(),
        "status": "pending",
        "state": state,
        "interval": max(5, int(out.get("interval") or 5)),
    }
    with _lock:
        _pending[state] = pending
    threading.Thread(target=_poll_microsoft_device, args=(state,), daemon=True).start()
    verification = out.get("verification_uri") or "https://microsoft.com/devicelogin"
    return {
        "ok": True,
        "state": state,
        "device": True,
        "user_code": out.get("user_code") or "",
        "verification_uri": verification,
        "verification_uri_complete": out.get("verification_uri_complete") or "",
        "message": out.get("message") or f"Go to {verification} and enter {out.get('user_code') or ''}",
    }


def _poll_microsoft_device(state: str) -> None:
    spec = PROVIDERS["microsoft"]
    client_id = db.setting(spec["client_id_key"])
    wait = 5
    while True:
        with _lock:
            pending = _pending.get(state)
        if not pending or pending.get("status") != "pending":
            return
        if time.time() - float(pending.get("created") or 0) > 900:
            mark_oauth_error(state, "Sign-in timed out. Start again.")
            return
        wait = max(wait, int(pending.get("interval") or 5))
        time.sleep(wait)
        try:
            tokens = _post_form(
                spec["token_url"],
                {
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": client_id,
                    "device_code": pending["device_code"],
                },
            )
        except Exception as exc:
            mark_oauth_error(state, str(exc))
            return
        err = tokens.get("error") or ""
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            wait += 5
            continue
        if err:
            mark_oauth_error(state, tokens.get("error_description") or err)
            return
        try:
            _account_from_tokens("microsoft", tokens, pending)
        except Exception as exc:
            mark_oauth_error(state, str(exc))
        return


def mark_oauth_error(state: str, message: str) -> None:
    with _lock:
        row = _pending.get(state)
        if row:
            row["status"] = "error"
            row["error"] = message


def access_token(account: dict[str, Any]) -> str:
    token = account.get("oauth_access_token") or ""
    expires = int(account.get("oauth_expires_at") or 0)
    if token and expires > int(time.time()) + 30:
        return token
    spec = PROVIDERS.get(account.get("provider") or "")
    if not spec or not account.get("oauth_refresh_token"):
        raise RuntimeError("This account needs to be signed in again.")
    client_id = db.setting(spec["client_id_key"])
    secret = db.setting(spec.get("client_secret_key") or "")
    data = {
        "client_id": client_id,
        "grant_type": "refresh_token",
        "refresh_token": account["oauth_refresh_token"],
    }
    if secret:
        data["client_secret"] = secret
    tokens = _post_form(spec["token_url"], data)
    if tokens.get("error"):
        raise RuntimeError(tokens.get("error_description") or tokens["error"])
    access = tokens.get("access_token") or ""
    expires = int(time.time()) + int(tokens.get("expires_in") or 3600) - 60
    refresh = tokens.get("refresh_token") or account["oauth_refresh_token"]
    db.execute(
        "UPDATE accounts SET oauth_access_token=?, oauth_refresh_token=?, oauth_expires_at=? WHERE id=?",
        (access, refresh, expires, account["id"]),
    )
    account["oauth_access_token"] = access
    account["oauth_refresh_token"] = refresh
    account["oauth_expires_at"] = expires
    return access


def xoauth2(user: str, token: str) -> str:
    return f"user={user}\x01auth=Bearer {token}\x01\x01"
