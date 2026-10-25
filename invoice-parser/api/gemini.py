"""Optional second reader: Google Gemini reads the receipt and the bank SMS
and says whether they describe the same payment.

On only when GEMINI_API_KEY is set. Standard library only, like the rest.
Nothing sent or returned is logged; on any failure the rule-based reading
stands alone.
"""

from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
import urllib.request

ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
DEFAULT_MODEL = "gemini-3.8-flash"
TIMEOUT = 25.0  # seconds, inside the app's 30 and Cloud Run's 60
MIME = {"pdf": "application/pdf", "jpeg": "image/jpeg", "png": "image/png", "heic": "image/heic"}

INSTRUCTIONS = """\
You check receipts for a work-travel expense app. You get a receipt (a PDF or
a photo), sometimes the text the phone already read off it, and the bank SMS
for the payment the receipt was attached to.

First read the receipt on its own and report only what it prints. Never copy
a value from the SMS into a receipt field; leave a field null when the
receipt doesn't show it.
- total_paid: the amount actually paid. A line naming the payment (Total
  payment, Amount paid, Total paid, You paid, Amount charged) beats Grand
  total: lower after a coupon, higher with a tip. Never an advance, deposit,
  balance due, wallet or points line.
- invoice_date as YYYY-MM-DD and invoice_time as HH:mm (24-hour): when the
  bill was issued or paid, not a due date. A hotel stay or a journey goes in
  period_start and period_end.
- merchant: the business as a customer would name it. legal_name: the
  registered company name, if printed and different.
- currency: ISO code (INR, USD, ...).

Then compare the receipt with the SMS:
- amount: the same, or the payment up to 15% higher (tip, round-off, fee).
- date: the same day, a bill near midnight, or a payment within the stay or
  journey.
- merchant: the same business. Banks shorten and capitalise names
  ("UBER INDIA"), and UPI handles carry the name before the "@".
verdict is "match" when every field you can compare agrees, "mismatch" when
any clearly disagrees, "unsure" when the receipt can't be read well enough.
explanation: one short plain sentence for the user, naming any difference.
"""

FIELDS = ("document_type", "merchant", "legal_name", "total_paid", "currency", "tax",
          "invoice_date", "invoice_time", "invoice_number", "period_start", "period_end")

SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "document_type": {"type": "STRING", "enum": [
            "ride", "airline", "rail", "hotel", "restaurant", "fuel", "gst_invoice", "unknown"]},
        "merchant": {"type": "STRING", "nullable": True},
        "legal_name": {"type": "STRING", "nullable": True},
        "total_paid": {"type": "NUMBER", "nullable": True},
        "currency": {"type": "STRING", "nullable": True},
        "tax": {"type": "NUMBER", "nullable": True},
        "invoice_date": {"type": "STRING", "nullable": True},
        "invoice_time": {"type": "STRING", "nullable": True},
        "invoice_number": {"type": "STRING", "nullable": True},
        "period_start": {"type": "STRING", "nullable": True},
        "period_end": {"type": "STRING", "nullable": True},
        "verdict": {"type": "STRING", "enum": ["match", "mismatch", "unsure"]},
        "explanation": {"type": "STRING"},
    },
    "required": ["document_type", "verdict", "explanation"],
    # Receipt first, comparison last: the reading is written before the SMS is weighed.
    "propertyOrdering": list(FIELDS) + ["verdict", "explanation"],
}


class Unavailable(Exception):
    """Gemini couldn't give an answer; the message is safe to show the user."""


def enabled() -> bool:
    return bool(os.environ.get("GEMINI_API_KEY"))


def model() -> str:
    return os.environ.get("GEMINI_MODEL") or DEFAULT_MODEL


def check(data: bytes, kind: str, client_text: str | None, hints: dict) -> dict:
    """The receipt's fields as Gemini reads them, plus its verdict on the SMS."""
    parts = [{"inline_data": {"mime_type": MIME[kind], "data": base64.b64encode(data).decode()}}]
    if client_text and client_text.strip():
        parts.append({"text": "Text the phone read off the receipt:\n" + client_text.strip()})
    parts.append({"text": payment_text(hints)})
    request = {
        "systemInstruction": {"parts": [{"text": INSTRUCTIONS}]},
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {
            "temperature": 0,
            "responseMimeType": "application/json",
            "responseSchema": SCHEMA,
        },
    }
    answer = call(request)
    try:
        text = "".join(p.get("text", "") for p in answer["candidates"][0]["content"]["parts"])
        reading = json.loads(text)
    except (KeyError, IndexError, TypeError, ValueError):
        raise Unavailable("Gemini's answer couldn't be read.") from None
    if reading.get("verdict") not in ("match", "mismatch", "unsure"):
        raise Unavailable("Gemini gave no verdict.")
    return reading


def payment_text(hints: dict) -> str:
    message = (hints.get("message") or "").strip()
    lines = ["The payment this receipt was attached to:"]
    if message:
        lines.append("Bank SMS: " + message)
    for label, key in (("Amount", "amount"), ("Currency", "currency"), ("Paid at", "date"),
                       ("Payee", "payee")):
        if hints.get(key) not in (None, ""):
            lines.append(f"{label}: {hints[key]}")
    return "\n".join(lines)


def call(request: dict) -> dict:
    """One retry when Google is busy, within the overall time limit."""
    body = json.dumps(request).encode()
    deadline = time.monotonic() + TIMEOUT
    for attempt in range(2):
        http = urllib.request.Request(
            ENDPOINT.format(model=model()), data=body, method="POST",
            headers={"Content-Type": "application/json",
                     "x-goog-api-key": os.environ["GEMINI_API_KEY"]})
        try:
            with urllib.request.urlopen(http, timeout=max(1.0, deadline - time.monotonic())) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            busy = error.code in (429, 500, 503)
            if busy and attempt == 0 and deadline - time.monotonic() > 8:
                time.sleep(1.5)
                continue
            if error.code == 402:
                raise Unavailable("The Gemini account has no credit left; top it up in AI Studio.") from None
            if error.code == 429:
                raise Unavailable("Gemini's quota is used up for now.") from None
            if error.code in (400, 403) and b"API_KEY" in error.read()[:2000]:
                raise Unavailable("The Gemini API key was refused.") from None
            raise Unavailable(f"Gemini answered {error.code}.") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Unavailable("Gemini didn't answer in time.") from None
        except ValueError:
            raise Unavailable("Gemini's answer couldn't be read.") from None
    raise Unavailable("Gemini is busy; try again shortly.")


def merge(rules: dict, reading: dict, hints: dict) -> dict:
    """Gemini's fields over the rules' wherever it read one; the rules fill
    the gaps. Its verdict goes in ai_check with the payment it judged, so
    the app can tell when the payment has been edited since."""
    result = dict(rules)
    confidence = dict(rules.get("confidence") or {})
    for field, key in (("merchant", "merchant"), ("total_paid", "total"),
                       ("invoice_date", "invoice_date"), ("invoice_time", "invoice_time")):
        if reading.get(field) not in (None, ""):
            result[key] = reading[field]
            confidence[key] = 0.9
    for key in ("legal_name", "currency", "tax", "invoice_number", "period_start", "period_end"):
        if reading.get(key) not in (None, ""):
            result[key] = reading[key]
    if reading.get("document_type") not in (None, "unknown"):
        result["document_type"] = reading["document_type"]
    if result.get("total") is not None:
        result["total"] = float(result["total"])
    result["confidence"] = confidence
    result["ai_check"] = {
        "verdict": reading["verdict"],
        "explanation": (reading.get("explanation") or "").strip(),
        "model": model(),
        "amount": hints.get("amount"),
        "date": hints.get("date"),
        "payee": hints.get("payee"),
    }
    return result
