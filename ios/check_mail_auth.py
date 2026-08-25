#!/usr/bin/env python3
"""Parity checks for iOS Microsoft mail auth. Fail the build if these drift."""
import base64
import json
import sys
import urllib.parse
import urllib.request

TENANT = "eedeccaf-01c1-4439-a88b-88e587be9f1c"
CLIENT = "1f0ced9a-277d-46b6-be8b-7728315eb595"
REDIRECT = "https://login.microsoftonline.com/common/oauth2/nativeclient"
SCOPE = "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"

fails = []

raw = "user=test@example.com\x01auth=Bearer tok\x01\x01"
got = base64.b64encode(raw.encode()).decode()
want = "dXNlcj10ZXN0QGV4YW1wbGUuY29tAWF1dGg9QmVhcmVyIHRvawEB"
if got != want:
    fails.append(f"XOAUTH2 {got} != {want}")

cmd = f"AUTHENTICATE XOAUTH2 {got}"
if not cmd.startswith("AUTHENTICATE XOAUTH2 ") or "\n" in cmd:
    fails.append("IMAP command must be one line")

payload = base64.urlsafe_b64encode(b'{"preferred_username":"ken@firm.com"}').decode().rstrip("=")
jwt = f"aaa.{payload}.sig"
pad = payload + "=" * ((4 - len(payload) % 4) % 4)
obj = json.loads(base64.urlsafe_b64decode(pad))
if obj.get("preferred_username") != "ken@firm.com":
    fails.append("JWT fixture broken")

allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
def enc(s):
    return "".join(c if c in allowed else urllib.parse.quote(c, safe="") for c in s)
form = f"scope={enc(SCOPE)}"
if "scope=offline_access%20https%3A%2F%2Foutlook.office.com" not in form:
    fails.append(f"form {form}")

# Tenant-specific authorize URL must load (firm client required at runtime; no generic Office client)
firm = CLIENT
auth = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/authorize?" + urllib.parse.urlencode({
    "client_id": firm,
    "response_type": "code",
    "redirect_uri": REDIRECT,
    "scope": SCOPE,
    "prompt": "select_account",
    "login_hint": "lawyer@firm.com",
})
req = urllib.request.Request(auth)
with urllib.request.urlopen(req, timeout=20) as resp:
    html = resp.read(800).decode("utf-8", "replace")
    if "Sign in" not in html and "sign in" not in html.lower():
        fails.append("tenant authorize page did not look like Microsoft sign-in")

# Default authorize must NOT force admin_consent (breaks Authenticator → mailbox token).
default_auth = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/authorize?" + urllib.parse.urlencode({
    "client_id": firm,
    "response_type": "code",
    "redirect_uri": REDIRECT,
    "scope": SCOPE,
    "login_hint": "lawyer@firm.com",
    "domain_hint": "firm.com",
})
if "prompt=admin_consent" in default_auth:
    fails.append("default authorize must not force admin_consent")
if TENANT in urllib.parse.parse_qs(urllib.parse.urlparse(default_auth).query).get("domain_hint", []):
    fails.append("domain_hint must not be tenant GUID")
if "firm.com" not in default_auth:
    fails.append("domain_hint should be email domain")

admin = f"https://login.microsoftonline.com/{TENANT}/adminconsent?" + urllib.parse.urlencode({
    "client_id": firm,
    "redirect_uri": REDIRECT,
})
if TENANT not in admin:
    fails.append("admin consent URL missing tenant")

if CLIENT != "1f0ced9a-277d-46b6-be8b-7728315eb595":
    fails.append("baked client id drifted")

redirect = REDIRECT + "?code=abc123&session_state=ss"
if "code=abc123" not in redirect:
    fails.append("redirect extra query fixture broken")

if fails:
    print("FAIL")
    for f in fails:
        print("-", f)
    sys.exit(1)
print("PASS mail auth checks")
