import os
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

from server import lawpay


class LawPayTests(unittest.TestCase):
    def invoice_payload(self):
        return {
            "matter_external_id": "matter-123",
            "client_name": "Ellen Ripley",
            "client_email": "eripley@example.com",
            "reference": "2026-DR-42",
            "source_id": "praecipe:invoice:invoice-123",
            "invoice_date": "2026-08-20",
            "entries": [
                {
                    "description": "Prepare motion",
                    "fee_cents": 12500,
                    "minutes": 30,
                    "rate": 250,
                }
            ],
            "send_email": True,
        }

    def test_invoice_uses_existing_contact_and_sends_portal_link(self):
        calls = []

        def fake_request(method, path, **kwargs):
            calls.append((method, path, kwargs))
            if path == "/contacts/source-id":
                return {"id": "p_contact"}
            if path == "/invoices":
                return {"id": "i_invoice", "invoice_number": "0000042", "status": "unpaid"}
            self.fail(f"Unexpected request {method} {path}")

        with patch.object(lawpay, "_request", side_effect=fake_request):
            result = lawpay.create_invoice(self.invoice_payload(), "bank_operating")

        self.assertEqual(result["invoice_id"], "i_invoice")
        invoice = calls[-1][2]["body"]
        self.assertEqual(invoice["contact_id"], "p_contact")
        self.assertEqual(invoice["bank_account_id"], "bank_operating")
        self.assertEqual(invoice["line_items"][0]["rate_per_quantity"], "12500")
        self.assertEqual(invoice["invoice_messages"][0]["email_addresses"], ["eripley@example.com"])
        self.assertEqual(invoice["source_id"], "praecipe:invoice:invoice-123")

    def test_invoice_creates_source_identified_contact_once(self):
        calls = []

        def fake_request(method, path, **kwargs):
            calls.append((method, path, kwargs))
            if path == "/contacts/source-id":
                raise lawpay.LawPayError("not found", 404)
            if path == "/contacts":
                return {"id": "p_new"}
            if path == "/invoices":
                return {"id": "i_invoice"}
            self.fail(f"Unexpected request {method} {path}")

        with patch.object(lawpay, "_request", side_effect=fake_request):
            result = lawpay.create_invoice(self.invoice_payload(), "bank_operating")

        contact_body = next(item[2]["body"] for item in calls if item[1] == "/contacts")
        self.assertEqual(contact_body["source_id"], "praecipe:matter:matter-123")
        self.assertEqual(contact_body["first_name"], "Ellen")
        self.assertEqual(contact_body["last_name"], "Ripley")
        self.assertEqual(result["contact_id"], "p_new")

    def test_invoice_rejects_zero_fee_before_calling_lawpay(self):
        payload = self.invoice_payload()
        payload["entries"][0]["fee_cents"] = 0
        with patch.object(lawpay, "_request") as request:
            with self.assertRaises(lawpay.LawPayError) as caught:
                lawpay.create_invoice(payload, "bank_operating")
        self.assertEqual(caught.exception.status, 400)
        request.assert_not_called()

    def test_authorization_uses_lawpay_and_csrf_state(self):
        env = {
            "PRAECIPE_LAWPAY_CLIENT_ID": "client-id",
            "PRAECIPE_LAWPAY_CLIENT_SECRET": "client-secret",
            "PRAECIPE_LAWPAY_REDIRECT_URI": "https://billing.example.com/oauth/lawpay",
        }
        with patch.dict(os.environ, env, clear=False):
            url = lawpay.new_authorization()
        parsed = urlparse(url)
        query = parse_qs(parsed.query)
        self.assertEqual(f"{parsed.scheme}://{parsed.netloc}{parsed.path}", lawpay.AUTHORIZE_URL)
        self.assertEqual(query["scope"], ["payments"])
        self.assertEqual(query["response_type"], ["code"])
        self.assertEqual(query["redirect_uri"], [env["PRAECIPE_LAWPAY_REDIRECT_URI"]])
        self.assertGreaterEqual(len(query["state"][0]), 32)


if __name__ == "__main__":
    unittest.main()
