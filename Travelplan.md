# Build Plan: Trip Receipts (iOS)

Companion to `spec.md`. Ordered by dependency, not by calendar. Each stage ends with something you can check on your own iPhone.

---

## Stack

| Layer | Choice |
|---|---|
| UI | SwiftUI, iOS 17+ |
| Storage | SwiftData, one `ModelContainer.shared` for app and intent alike (receipts as external-storage blobs) |
| SMS capture | Shortcuts personal automation → App Intent `CheckPaymentMessageIntent` |
| Questions | `UserNotifications` with action buttons, handled in `AppDelegate` |
| Receipts | VisionKit document camera, PhotosPicker, file importer |
| Reading receipts | Vision text recognition, PDFKit |
| Export | `UIGraphicsPDFRenderer` (PDF), CSV, ShareLink |
| Proof fingerprint | CryptoKit SHA-256 |

No server, no third-party packages.

## Project layout

```
TripReceipts.xcodeproj
TripReceipts/
  App/            TripReceiptsApp (entry, Router, AppDelegate, notification actions)
  Intents/        CheckPaymentMessageIntent, App Shortcuts
  Models/         Payment, Trip, ReceiptFile
  Services/       SMSParser, PaymentStore, NotificationManager, ReceiptOCR, ReportBuilder, ProofHasher
  Views/          Inbox, Expenses, Trips, Setup, PaymentDetail, AddPayment, Receipt views
  Assets.xcassets
ParserCheck/                  sample-SMS tests for the parser patterns
```

## Stages

### Stage 1 — Parser
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
- **Check:** create a trip for today, send a test payment, tap *Yes, work travel*; it appears under the trip.

### Stage 4 — Receipts and proof
- Scan / Photos / PDF; on-device total reading and match check.
- Proof section with original SMS, extra SMS, fingerprint and integrity check.
- **Check:** scan any bill against a payment; the total should be read and compared.

### Stage 5 — Export
- PDF pack (summary, line items, proof pages with receipts) and CSV.
- **Check:** Trips → a trip → Export → open the PDF.

### Stage 6 — Run it in Xcode and watch one Uber debit go through

The whole-app check, done in the simulator before any device signing. Target:
**iPhone 18 Pro, iOS 27**. Run it from Xcode (`open TripReceipts.xcodeproj`,
then ⌘R) rather than from the command line — the simulator window is what lets
you answer the notification, and `simctl` cannot tap an alert.

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

- **Check:** steps 4 through 8 complete without opening a single Xcode log —
  parsed, asked, filed under the trip, and the proof intact.

### Stage 7 — On your iPhone
- Open in Xcode, pick your Apple ID team, run on the phone.
- Create the five Shortcuts automations.
- Use it on a real trip. Add any SMS that wasn't parsed well to the sample suite and adjust the patterns.

### Stage 8 — Next improvements
- Auto-file rules per payee.
- Policy caps and warnings.
- Email-forwarding inbox for invoices (needs a small server).
- iCloud sync / backup.
- Exchange-rate conversion for foreign card spends.
- Direct export to company expense tools.

## Testing

| Area | How |
|---|---|
| Parser | Sample-SMS suite; add every misread real SMS as a case |
| Capture | Shortcuts → run *Check Payment Message* manually with pasted text |
| Notifications | Lock the phone, send a test payment, answer from the lock screen |
| Whole app | Stage 6: Xcode → iPhone 18 Pro → the Uber debit, parse to filed |
| Duplicates | Run the same message twice; only one question should appear |
| Receipts | Scan a printed bill, import a PDF invoice, pick a screenshot |
| Export | Generate a trip report, open PDF and CSV on the phone and a laptop |

## Risks

| Risk | Mitigation |
|---|---|
| Automation keyword misses an SMS format | Five keywords; paste-in fallback; add keywords as needed |
| Bank changes SMS wording | Original SMS and amount still captured; patterns in one file; check script |
| Free Apple ID signing expires after 7 days | Re-run from Xcode, or use a paid developer account for 1-year signing |
| Simulator crawls on a loaded 8 GB Mac | Quit other apps before Stage 6; boot and first launch can take minutes under memory pressure, which is the host, not the app |
| Wrong receipt total read | Shown as a hint only; never changes the payment amount |
