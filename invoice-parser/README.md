# invoice-parser

The online half of Trip Receipts' receipt check. The app sends a receipt it
has just attached; this returns what the receipt states — total, date, time,
merchant — so the phone can compare them with the payment.

Python 3.9+, standard library only. Nothing to install. Optionally Google
Gemini reads each receipt too and judges it against the payment's SMS
(*Gemini*, below).

```
python3 server.py                          # http://127.0.0.1:8787
python3 server.py --host 0.0.0.0 --port 8080
python3 check_fixtures.py                  # every fixture read as expected
python3 check_fixtures.py --gemini         # and Gemini's verdicts, live (GEMINI_API_KEY)
../Tools/invoice-parser-check.sh           # fixtures, then the real HTTP server
```

## API

| Call | Does |
|---|---|
| `GET /v1/health` | `{"ok": true, "version": "1", "server_ocr": false}`. Also `/healthz` locally; Cloud Run answers that path itself. |
| `POST /v1/install` | `{"token": "tr1…"}` — one per app install, 10 per hour per address |
| `POST /v1/parse` | multipart: `file` (PDF, JPEG, PNG, HEIC), optional `text` (what the phone read), optional `hints` (JSON: `amount`, `currency`, `date`, `payee`, `message` — the SMS). `Authorization: Bearer <token>`. 20 a minute, 400 a day per token. |

```
curl -s -X POST localhost:8787/v1/install
curl -s -H "Authorization: Bearer $TOKEN" -F file=@fixtures/uber_ride_pdf.pdf localhost:8787/v1/parse
```

```json
{
  "document_type": "ride",
  "merchant": "Uber", "legal_name": "Uber India Systems Private Limited",
  "total": 486.0, "currency": "INR", "tax": null,
  "invoice_date": "2025-10-12", "invoice_time": "09:41", "invoice_number": null,
  "period_start": null, "period_end": null,
  "line_items": [{"description": "Trip fare", "amount": 455.5}, …],
  "confidence": {"merchant": 0.9, "total": 0.9, "invoice_date": 0.75, "invoice_time": 0.9},
  "text_source": "pdf-text-layer", "file_type": "pdf", "version": "1"
}
```

`period_start`/`period_end` carry a hotel stay or a journey date, so a payment
made mid-stay isn't flagged. The rule-based reader takes only the currency from
the hints, and only when the invoice prints none: a total chosen because it
equals the payment would make the check an echo.

With Gemini on, the answer also carries `ai_check` — `{"verdict": "match" |
"mismatch" | "unsure", "explanation": "…", "model": "…"}` plus the amount, date
and payee it judged — or `ai_error` with the reason it didn't answer.

## Gemini

Set `GEMINI_API_KEY` and each receipt also goes to Google's Gemini API
(`api/gemini.py`, plain HTTPS, `GEMINI_MODEL` to change the default
`gemini-3.8-flash`), with the phone's text and the hints, SMS included. Gemini
is asked to read the receipt first, printing only what the receipt shows, and
only then to compare it with the SMS; the answer is held to a JSON schema.
Every field Gemini read replaces the rules' reading (confidence 0.9); the rules
fill what it left empty. On any failure — no credit, quota, a timeout after
25 s, an unreadable answer — the rules' reading is returned alone with
`ai_error`, so a receipt is never lost to Gemini being down.

The app compares Gemini's fields with the payment like any reading. Its
verdict can add a warning but never clear one, so seeing the SMS can't make a
wrong receipt pass.

## How it reads

1. **Text.** A PDF's own text layer (`reading/pdf_text.py`: Flate streams,
   embedded fonts with ToUnicode maps, object streams). For a photo, the text
   the phone sent — Apple's Vision beats server OCR on a crumpled bill — or
   Tesseract if the host has it.
2. **Type.** Ride, airline, rail, hotel, restaurant, fuel, or a plain GST
   invoice, from keywords (`extractors/*.py`).
3. **Fields.** The type's labels, most trusted first (`extractors/common.py`).
   Unlabelled guesses get a confidence under 0.6, which the app treats as not
   read — so an ambiguous bill comes back *unverified* rather than *wrong*.
4. **The total is what was paid.** A line naming the payment — *Total
   payment*, *Amount paid*, *Total paid*, *You paid*, *Amount charged*,
   *Amount received* (`PAID_TOTALS`) — beats every other total, since that is
   the figure the bank SMS carries: below the grand total after a coupon,
   above it with a tip. Only then the type's labels (*Total fare*, *Grand
   total*, …), then the generic ones. "(incl. tip)" or "including taxes"
   beside it doesn't disqualify the line. Still skipped: advances, deposits,
   balances, wallet and points lines, zero amounts, and *Paid by* / *Paid via*,
   which are usually followed by card digits rather than an amount. With a
   split payment, the last paid line wins — the card or UPI share the bank
   reported.

## Privacy

Files are read in memory and dropped with the request. Nothing about content —
not the file, its name, its text or the result — is stored or logged; the log
line is method, path, status, size and time. Tokens are signed, not stored.
With `GEMINI_API_KEY` set, the file, the phone's text and the hints go to
Google, whose terms for that key decide what it keeps.

## Hosting

Any host that runs Python works; put it behind HTTPS (the app only uses plain
HTTP for addresses on your own network). Set:

- `PARSER_TOKEN_SECRET` — a long random string, so tokens survive restarts.
- `PORT` / `HOST` — where to listen.
- `GEMINI_API_KEY` — optional; turns Gemini on. Keep it in a secret store,
  never in the app or the repo.
- `PARSER_TRUST_PROXY=1` — only behind a proxy that sets `X-Forwarded-For`
  as its first entry. Leave it off on Cloud Run, which appends the caller
  last: installs are then limited per host rather than per caller, which is
  plenty for one phone.

### Cloud Run

`Dockerfile` builds it; Cloud Run gives a fixed `https://….run.app` address,
scales to zero when idle and wakes in a second or two — inside the app's 30 s
limit — so the phone can always reach it at no cost at this volume.

```
gcloud run deploy invoice-parser --source . --region asia-south1 \
  --allow-unauthenticated --max-instances 2 --memory 512Mi --timeout 60 \
  --set-env-vars PARSER_TOKEN_SECRET=$(openssl rand -hex 32)
```

Run it from this folder. Deploy again with the same command, minus
`--set-env-vars`, to ship a change without signing out every install.

Gemini's key lives in Secret Manager as `gemini-api-key`, readable by the
service's account, and reaches the server as `GEMINI_API_KEY`:

```
gcloud secrets create gemini-api-key --data-file=-          # paste, then Ctrl-D
gcloud secrets add-iam-policy-binding gemini-api-key \
  --member serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com \
  --role roles/secretmanager.secretAccessor
gcloud run deploy invoice-parser --source . --region asia-south1 \
  --timeout 60 --update-secrets GEMINI_API_KEY=gemini-api-key:latest
```

A new key later is `gcloud secrets versions add gemini-api-key --data-file=-`;
it is picked up by the next deploy. Then
put the printed address in the app: Setup → *Receipt check* → *Check
connection*.

## Fixtures

`fixtures/` holds invented invoices — text as the phone would read it, PDFs
(one printed by Chrome, one plain), and a photo with the phone's text beside
it — each with an `.expected.json`. When a real invoice is misread, add it
here, with its expected fields, before touching an extractor.
