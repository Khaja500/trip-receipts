# Build Plan: Trip Receipts (iOS + verification service)

Companion to `spec.md`. Ordered by dependency, not by calendar. Each stage ends with something you can check on your own iPhone.

**Core rule of the receipt check:** an attached invoice is verified against the payment (amount, date/time, merchant). A mismatch produces a **warning, never a block**. The user can always choose *Add to trip anyway*, and the flag travels with the expense into the proof section and the export.

---

## Stack

| Layer | Choice |
|---|---|
| UI | SwiftUI, iOS 17+ |
| Storage | SwiftData, one `ModelContainer.shared` for app and intent alike (receipts as external-storage blobs) |
| SMS capture | Shortcuts personal automation → App Intent `CheckPaymentMessageIntent` |
| Questions | `UserNotifications` with action buttons, handled in `AppDelegate` |
| Receipts | VisionKit document camera, PhotosPicker, file importer |
| Receipt capture-side reading | Vision text recognition, PDFKit (on-device fallback and pre-upload text layer) |
| **Online invoice parser** | Small HTTPS service `invoice-parser/` (see below); app talks to it through `InvoiceParseClient` |
| **Verification** | `ReceiptVerifier` (on device) compares parser output with the payment |
| Export | `UIGraphicsPDFRenderer` (PDF), CSV, ShareLink |
| Proof fingerprint | CryptoKit SHA-256 |

No third-party packages in the app. The one server component is the invoice parser; everything else works offline.

### Online invoice parser (service)

- `POST /v1/parse` accepts a receipt/invoice (PDF, JPEG/PNG/HEIC) plus optional hints (expected amount, expected date, payee). It returns structured JSON only:
  `merchant`, `total`, `currency`, `tax`, `invoice_date`, `invoice_time` (nullable), `invoice_number`, `line_items[]`, and per-field `confidence`.
- Parsing pipeline on the server: text-layer extraction for PDFs, OCR for images, then a field extractor tuned for Indian invoices (GST invoices, Uber/Ola/Rapido ride receipts, airline and IRCTC tickets, hotel folios, restaurant bills).
- The server is stateless about content: files are processed in memory and **not stored or logged**; only request metadata (size, latency, status) is kept. Receipts leave the phone only when the user attaches one.
- Auth: per-install API token issued on first launch; rate-limited. HTTPS only, certificate pinning optional later.
- If the service is unreachable, slow (>10 s) or returns low confidence, the app falls back to the on-device Vision/PDFKit reader and marks the result **Unverified**, not *Mismatch*.

## Project layout

```
TripReceipts.xcodeproj
TripReceipts/
  App/            TripReceiptsApp (entry, Router, AppDelegate, notification actions)
  Intents/        CheckPaymentMessageIntent, App Shortcuts
  Models/         Payment, Trip, ReceiptFile, ReceiptVerification
  Services/       SMSParser, PaymentStore, NotificationManager, ReceiptOCR (fallback),
                  InvoiceParseClient, ReceiptVerifier, ReportBuilder, ProofHasher
  Views/          Inbox, Expenses, Trips, Setup, PaymentDetail, AddPayment,
                  Receipt views, VerificationBanner, AddAnywaySheet
  Assets.xcassets
ParserCheck/                  sample-SMS tests for the parser patterns
VerifierCheck/                sample payment + invoice pairs for the verifier (match / mismatch / unverified)
invoice-parser/               the online parsing service
  api/            /v1/parse endpoint, auth, rate limiting
  extractors/     per-merchant-type field extractors
  fixtures/       sample invoices with expected JSON
```

## Verification model

`ReceiptVerification` is stored on each receipt attached to a payment.

| Field | Meaning |
|---|---|
| `status` | `matched`, `warning`, `unverified` |
| `amountResult` | `match`, `close`, `mismatch`, `unread` |
| `timeResult` | `match`, `close`, `mismatch`, `unread` |
| `merchantResult` | `match`, `weak`, `mismatch`, `unread` |
| `parsedTotal`, `parsedDate`, `parsedTime`, `parsedMerchant` | What the parser read (shown to the user, never overwrites the payment) |
| `source` | `online` or `on-device` |
| `overriddenByUser` | True if the user chose *Add to trip anyway* on a warning |
| `userNote` | Optional reason typed in the Add-anyway sheet |

**Default rules** (all values live in one `VerifierRules.swift` so they are easy to tune):

| Check | Match | Close (soft warning) | Mismatch (warning) |
|---|---|---|---|
| Amount | Invoice total within ₹1 of payment | Payment is higher than invoice by up to 15% (tip, round-off, convenience fee) | Anything else |
| Date/time | Same timestamp within ±30 min when the invoice has a time | Same calendar day, or ±1 day around midnight; for hotels and multi-day tickets, payment date inside the stay or travel window | Outside those |
| Merchant | Normalised names match or one contains the other (e.g. *UBER INDIA* / *Uber India Systems Pvt Ltd*) | Fuzzy score above threshold | Below threshold |

Overall `status`: any *mismatch* → `warning`; all *match* → `matched`; *close* only → `matched` with a visible note; parser failed or low confidence → `unverified`.

**Warning behaviour:** a banner on the receipt and payment detail says exactly what differs (e.g. *Invoice total ₹842 vs payment ₹1,250; invoice dated 3 Oct vs payment 9 Oct*). Two buttons: **Fix the receipt** (rescan or choose another file) and **Add to trip anyway**. The second never asks for a password or a reason, but offers an optional note. The expense is filed under the trip with a ⚠ badge.

## Stages

### Stage 1 — Parser (SMS)
- Rule-based parser for Indian bank / card / UPI SMS.
- Filters for OTP, requests, failed, upcoming, credits, promos.
- Sample-message test suite covering the major banks and the ignore cases.
- **Check:** every sample parses to the expected amount, payee and direction.

### Stage 2 — Capture and the question
- App Intent callable from a Shortcuts automation, runs without opening the app.
- The intent opens a `ModelContext` against `ModelContainer.shared` — never its
  own container, or a payment captured while the app is open stays invisible to
  the Inbox until relaunch.
- Duplicate detection (same text, same reference, same amount + payee within 15 min).
- Notification with Yes / Work + receipt / Personal; follow-up "Add receipt" nudge; 9 pm reminder.
- **Check:** Setup tab → *Send a test payment* → answer from the notification.

### Stage 3 — Inbox, trips, expenses
- Inbox with swipe triage, bulk actions, personal history.
- Trips with date windows and auto-filing.
- Work expenses grouped by trip, filters, totals.
- Expense rows show a verification badge: ✓ verified, ⚠ warning, ○ unverified, none if no receipt yet.
- **Check:** create a trip for today, send a test payment, tap *Yes, work travel*; it appears under the trip.

### Stage 4 — Online invoice parser service
- Build `invoice-parser/`: `/v1/parse`, token auth, rate limiting, in-memory processing, no content logging.
- Extractors for ride receipts, GST invoices, airline/train tickets, hotel folios, restaurant bills.
- Fixture suite: sample invoices with expected JSON (total, date, time, merchant). Add every misread real invoice as a fixture.
- Deploy to a small hosted instance; health-check endpoint.
- **Check:** run the fixture suite; every fixture returns the expected total, date and merchant. `curl` a sample PDF and get JSON back.

### Stage 5 — Receipts, verification and the warning flow
- Scan / Photos / PDF attach flow on a payment.
- `InvoiceParseClient` uploads the file, shows a progress state, times out to the on-device reader.
- `ReceiptVerifier` compares parser output with the payment using the rules above; writes a `ReceiptVerification`.
- `VerificationBanner` and `AddAnywaySheet`: warning explains each mismatch, offers **Fix the receipt** or **Add to trip anyway**, with optional note.
- A payment can be filed to a work trip with a failing or unverified receipt; the flag and `overriddenByUser` are kept.
- Proof section: original SMS, extra SMS, fingerprint and integrity check, plus the parsed fields, verification result, source (online / on-device) and any user note.
- Verifier fixture suite `VerifierCheck/`: matching pair, amount mismatch, date mismatch, wrong merchant, tip case, hotel multi-day, parser failure.
- **Check:** attach a correct invoice → ✓. Attach one with a different total → ⚠ with the reason, then *Add to trip anyway* files it under the trip with the badge. Turn on airplane mode, attach a bill → ○ Unverified, still addable.

### Stage 6 — Export
- PDF pack (summary, line items, proof pages with receipts) and CSV.
- Each line item and proof page carries its verification status; warnings and user overrides are listed explicitly, with the mismatch reason and note.
- CSV adds columns: `verification_status`, `parsed_total`, `parsed_date`, `overridden`, `note`.
- **Check:** Trips → a trip → Export → open the PDF; the flagged expense is clearly marked and the reason is readable.

### Stage 7 — Run it in Xcode and watch one Uber debit go through

The whole-app check, done in the simulator before any device signing. Target:
**iPhone 18 Pro, iOS 27**. Run it from Xcode (`open TripReceipts.xcodeproj`,
then ⌘R) rather than from the command line — the simulator window is what lets
you answer the notification, and `simctl` cannot tap an alert. Point the app at
the parser service (hosted or a local instance) in Setup → *Parser server*.

The message under test is the one *Send a test payment* generates, a real-shaped
HDFC debit to Uber:

```
Sent Rs.<amount>.00 From HDFC Bank A/C x1234 To UBER INDIA
On <today> Ref <12-digit> Not You? Call 18002586161
```

Walk it in this order, checking each line before the next:

| # | Do | Expect |
|---|---|---|
| 1 | ⌘R in Xcode, destination **iPhone 18 Pro** | App opens on the Inbox tab, four tabs along the bottom |
| 2 | Tap **Allow** on the notification prompt | Setup tab shows notifications as on |
| 3 | Trips → **+**, a trip covering today | The trip is listed with today inside its window |
| 4 | Setup → **Send a test payment** | Line under the button: *Asked about ₹N to Uber India* |
| 5 | Look at the notification | Title names the amount and Uber India; three buttons: *Yes, work travel* / *Work – add receipt* / *Personal* |
| 6 | Inbox tab | One pending payment, amount and payee as parsed |
| 7 | Tap **Yes, work travel** | Leaves the Inbox, appears under the trip from step 3, category guessed as a ride |
| 8 | Open it → Proof | Original SMS verbatim, sender `AD-HDFCBK`, fingerprint shown as matching |
| 9 | Press **Send a test payment** twice quickly | Second one may say *already in the inbox* — the duplicate rule working, not a bug |
| 9b | With the app open on Inbox, run the intent from Shortcuts | The payment appears without relaunching — the shared-container fix |
| 10 | ⌘L to lock, then send one more | The question is answerable from the lock screen |
| 11 | Open the filed payment → **Add receipt**, pick the sample Uber invoice with the same total and today's date | Parser reads total, date, merchant; banner shows ✓ *Matches payment* |
| 12 | Attach the sample invoice with a **different total** (and an old date) | ⚠ banner naming both differences, *Fix the receipt* and *Add to trip anyway* offered |
| 13 | Tap **Add to trip anyway** | Receipt stays on the expense under the trip, ⚠ badge in the list, Proof shows the mismatch and override |
| 14 | Turn the parser server off, attach any bill | ○ *Couldn't verify online*, on-device reading used, still addable |
| 15 | Trips → the trip → Export → open the PDF | Flagged expense marked with its reason; verified expenses show ✓ |

- **Check:** steps 4 through 8 complete without opening a single Xcode log —
  parsed, asked, filed under the trip, and the proof intact. Steps 11 through 15
  show verified, warned-but-added, and unverified receipts all end up in the report.

### Stage 8 — On your iPhone
- Open in Xcode, pick your Apple ID team, run on the phone.
- Create the five Shortcuts automations.
- Use it on a real trip. Add any SMS that wasn't parsed well to the sample suite, and any invoice that was misread or wrongly flagged to the parser fixtures and verifier cases; adjust patterns and tolerances.

### Stage 9 — Next improvements
- Auto-file rules per payee.
- Policy caps and warnings.
- Email-forwarding inbox for invoices (the parser service already exists, so this adds an inbound mail hook rather than a new server).
- Per-merchant verifier rules (e.g. airline refunds, hotel incidentals).
- iCloud sync / backup.
- Exchange-rate conversion for foreign card spends and foreign-currency invoices.
- Direct export to company expense tools.

## Testing

| Area | How |
|---|---|
| SMS parser | Sample-SMS suite; add every misread real SMS as a case |
| Invoice parser | `invoice-parser/fixtures` suite; add every misread real invoice as a case |
| Verifier | `VerifierCheck/` pairs: match, amount mismatch, date mismatch, wrong merchant, tip, multi-day stay, parser failure |
| Capture | Shortcuts → run *Check Payment Message* manually with pasted text |
| Notifications | Lock the phone, send a test payment, answer from the lock screen |
| Whole app | Stage 7: Xcode → iPhone 18 Pro → the Uber debit, parse to filed, then receipt verified, warned and unverified |
| Duplicates | Run the same message twice; only one question should appear |
| Receipts | Scan a printed bill, import a PDF invoice, pick a screenshot |
| Offline | Airplane mode / server off: attach a receipt, expect Unverified and still addable |
| Export | Generate a trip report with one ✓, one ⚠ (overridden) and one ○ expense; open PDF and CSV on the phone and a laptop |

## Risks

| Risk | Mitigation |
|---|---|
| Automation keyword misses an SMS format | Five keywords; paste-in fallback; add keywords as needed |
| Bank changes SMS wording | Original SMS and amount still captured; patterns in one file; check script |
| Free Apple ID signing expires after 7 days | Re-run from Xcode, or use a paid developer account for 1-year signing |
| Simulator crawls on a loaded 8 GB Mac | Quit other apps before Stage 7; boot and first launch can take minutes under memory pressure, which is the host, not the app |
| Parser misreads an invoice and raises a false warning | Warning is never a block; user sees what was read and can add anyway; misreads become fixtures |
| Parser misses a real mismatch (false match) | Parsed fields are always shown beside the payment; original receipt stays in the proof; verification is a check, not a guarantee |
| Receipts contain personal data sent to a server | Sent only when the user attaches a receipt; processed in memory, not stored or logged; HTTPS; clear note in Setup |
| Parser service down or slow | 10 s timeout, on-device fallback, status *Unverified*; attaching never fails because of the server |
| Legitimate differences (tip, round-off, multi-day hotel stay) | *Close* tier and per-category date windows; rules in one file for tuning |
| Hosting and upkeep of the parser service | Stateless, small footprint; health check; keep it separate from the app so it can be swapped or self-hosted |
| Invoice total read wrongly | Parsed total is shown for comparison only; never changes the payment amount |