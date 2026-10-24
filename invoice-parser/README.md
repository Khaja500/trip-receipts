# invoice-parser

The online half of Trip Receipts' receipt check. The app sends a receipt it
has just attached; this returns what the receipt states — total, date, time,
merchant — so the phone can compare them with the payment.

Python 3.9+, standard library only. Nothing to install.

```
python3 server.py                          # http://127.0.0.1:8787
python3 server.py --host 0.0.0.0 --port 8080
python3 check_fixtures.py                  # every fixture read as expected
../Tools/invoice-parser-check.sh           # fixtures, then the real HTTP server
```

## API

| Call | Does |
|---|---|
| `GET /v1/health` | `{"ok": true, "version": "1", "server_ocr": false}`. Also `/healthz` locally; Cloud Run answers that path itself. |
| `POST /v1/install` | `{"token": "tr1…"}` — one per app install, 10 per hour per address |
| `POST /v1/parse` | multipart: `file` (PDF, JPEG, PNG, HEIC), optional `text` (what the phone read), optional `hints` (JSON). `Authorization: Bearer <token>`. 20 a minute, 400 a day per token. |

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
made mid-stay isn't flagged. Hints are accepted but only the currency is used,
and only when the invoice prints none: a total chosen because it equals the
payment would make the check an echo.

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

## Privacy

Files are read in memory and dropped with the request. Nothing about content —
not the file, its name, its text or the result — is stored or logged; the log
line is method, path, status, size and time. Tokens are signed, not stored.

## Hosting

Any host that runs Python works; put it behind HTTPS (the app only uses plain
HTTP for addresses on your own network). Set:

- `PARSER_TOKEN_SECRET` — a long random string, so tokens survive restarts.
- `PORT` / `HOST` — where to listen.
- `PARSER_TRUST_PROXY=1` — only behind a proxy that sets `X-Forwarded-For`
  as its first entry. Leave it off on Cloud Run, which appends the caller
  last: installs are then limited per host rather than per caller, which is
  plenty for one phone.

### Cloud Run

`Dockerfile` builds it; Cloud Run gives a fixed `https://….run.app` address,
scales to zero when idle and wakes in a second or two — inside the app's 10 s
limit — so the phone can always reach it at no cost at this volume.

```
gcloud run deploy invoice-parser --source . --region asia-south1 \
  --allow-unauthenticated --max-instances 2 --memory 512Mi --timeout 30 \
  --set-env-vars PARSER_TOKEN_SECRET=$(openssl rand -hex 32)
```

Run it from this folder. Deploy again with the same command, minus
`--set-env-vars`, to ship a change without signing out every install. Then
put the printed address in the app: Setup → *Receipt check* → *Check
connection*.

## Fixtures

`fixtures/` holds invented invoices — text as the phone would read it, PDFs
(one printed by Chrome, one plain), and a photo with the phone's text beside
it — each with an `.expected.json`. When a real invoice is misread, add it
here, with its expected fields, before touching an extractor.
