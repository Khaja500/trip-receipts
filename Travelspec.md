# Spec: Trip Receipts (iOS)

**Status:** Draft v0.3, 22 Oct 2026 (adds §11, the website)
**Platform:** iPhone, iOS 17 or later

---

## 1. Problem

Work-travel payments (cabs, trains, flights, hotels, meals) are made from personal UPI and cards. At claim time, people dig through SMS, email and apps to find each payment, its invoice and proof that it was paid. Things get missed; claims get rejected.

Every one of those payments produces a bank SMS the moment it happens. That is the moment to ask: **"Was this for work travel?"**

## 2. Goals

1. Catch every outgoing payment SMS and ask, within seconds, whether it was for work travel.
2. Turn a "yes" into an expense that carries **proof of payment** (the original bank SMS, untouched) and a **receipt** (bill, ticket or invoice).
3. Group expenses into trips and export a reimbursement-ready pack (PDF + CSV).
4. Keep everything on the phone. Nothing is uploaded unless website sync (§11) is turned on.

**Not in scope:** budgeting or tracking personal spend, bank account linking, company expense-system integrations, manager approvals.

## 3. How the iPhone sees SMS

iOS does not let any third-party app read SMS. The app gets messages through **Shortcuts personal automations**:

- Trigger: *Message* → *Message Contains* a keyword (`debited`, `spent`, `sent`, `paid`, `withdrawn`), sender left empty.
- Set to *Run Immediately* with *Notify When Run* off, so it is silent and needs no tap.
- Action: the app's **Check Payment Message** action (an App Intent), with *Message* set to *Shortcut Input*.

One automation per keyword. The app runs in the background, parses the text and decides whether to ask. If a message matches two automations it is recognised as the same message and only asked once.

Fallback paths: paste an SMS into the app, or add a payment manually (cash, anything without an SMS).

## 4. Core flow

```
Payment SMS arrives
  → Shortcuts automation passes the text to "Check Payment Message"
  → Ignore if: OTP, payment request, failed/declined, upcoming debit or due notice, money received, promo
  → Parse: amount, currency, payee, method (UPI / card ••last4 / A/c ••last4), reference no., date, bank
  → Duplicate? (same text; or same amount + same reference; or same amount + similar payee within 15 min)
       yes → keep the extra SMS as additional proof, don't ask again
  → Save as "pending" and send a notification:

      ₹486 paid to UBER INDIA
      Was this for work travel?
      Cab / Taxi · during Pune client visit · Via UPI · A/c ••1234

      [Yes, work travel]  [Work – add receipt now]  [Personal]
```

| Answer | What happens |
|---|---|
| **Yes, work travel** | Marked work, filed to the trip covering that date. A second notification offers **Add receipt**. Works from the lock screen without opening the app. |
| **Work – add receipt now** | Marked work, app opens on that payment with the receipt picker. |
| **Personal** | Moved out of the inbox. Kept 30 days (to catch duplicates and allow undo), then deleted. |
| No answer | Stays in the Inbox. A 9 pm reminder fires if anything is still waiting. |

Refund or reversal SMS: matched to the original payment by reference or amount; the claimable amount is reduced and a notification says so.

## 5. Features (v1)

### Inbox
- Pending payments, newest first. Swipe right = work, swipe left = personal; long-press to file into a specific trip.
- "Mark all as work / personal" when several are waiting.
- Add payment: paste an SMS, or enter manually.
- "Marked personal" history with undo.

### Payment detail
- Amount, payee, date, method, status.
- Editable payee, category, trip, amount to claim (for partly personal bills), date, notes.
- Receipts: document camera scan (auto-crop), Photos, or Files (PDF). Several per payment.
- On-device text recognition reads the receipt total and shows whether it matches the payment (±1%).
- Attaching a receipt to a pending payment marks it as work.

### Proof of payment
- Original SMS text kept verbatim, with sender and received time.
- Extra SMS for the same payment (bank + UPI app) kept alongside.
- SHA-256 fingerprint of sender + received time + text, taken at capture. The app shows whether the stored text still matches; the report prints the fingerprint.

### Trips
- Name, destination, start/end dates, purpose/client/cost centre.
- Payments within the trip's dates — its start date to its end date, no margin either side — file to the trip automatically when marked work. A payment outside them can't be put in the trip at all: the trip menus only offer trips whose dates include the payment, and changing a payment's or a trip's dates takes out anything that no longer fits.
- Creating a trip can sweep in work expenses already made in those dates.
- Trip view: total to claim, missing-receipt count, list of expenses, export.

### Work expenses
- All work expenses grouped by trip, with a running total and missing-receipt count.
- Filter: all, missing receipts, not in a trip, one trip.
- Move back to inbox.

### Export
- **PDF**: summary (total, by category), line items, then one page per expense with details, the original SMS as proof, the fingerprint, and the receipt images (PDF invoices rendered page by page).
- **CSV**: one row per expense incl. reference, method, receipt count, original SMS and fingerprint.
- Shared through the iOS share sheet (Mail, WhatsApp, Files, Drive…).

### Categories
Airfare, Rail, Cab / Taxi, Local transport, Hotel, Meals, Fuel, Tolls / Parking, Visa / Forex, Other. Guessed from the payee (Uber, Ola, Rapido, IRCTC, IndiGo, MakeMyTrip, OYO, Swiggy, FASTag, HPCL…), editable.

### Notification hints
The question includes why it might be work: travel category, an active trip, or the payee having been marked work before.

## 6. SMS parsing

Rule-based, tuned for Indian bank, card and UPI messages (HDFC, ICICI, SBI, Axis, Kotak, and the generic "debited / spent / sent / paid" shapes).

| Field | Notes |
|---|---|
| Amount + currency | `Rs.` `INR` `₹` and foreign codes (USD, EUR, GBP, AED, SGD…). Amounts after "Avl Bal" / "Limit" are skipped. |
| Direction | debit, credit (ignored), refund/reversal (matched to an earlier payment). |
| Payee | Axis `UPI/P2M/<ref>/<name>`, ICICI `; <name> credited`, card `at <merchant>`, UPI `to <name or VPA>`. |
| Method | Card ••last4 / UPI · A/c ••last4 / NEFT / IMPS / RTGS / Wallet. |
| Reference | UPI Ref / Ref No / RRN / UTR / Txn ID. |
| Date | dd/mm/yy, dd-Mon-yy, ddMonyy, yyyy-mm-dd. Used only if within the last 45 days. |

Never stored: OTP messages, non-payment texts, full account numbers.

A set of sample bank messages (HDFC, ICICI, SBI, Axis, Kotak, card, foreign card, OTP, request, failed, refund) is kept as a test suite; every misread real SMS is added to it.

## 7. Data model (SwiftData)

```
Payment   amount, currency, merchant, instrument, reference, bank, paidAt
          rawMessage, sender, receivedAt, messageHash, additionalMessages[]
          status (pending | work | personal), category, claimableAmount, refundedAmount
          notes, isManual, parseConfidence, reviewedAt
          trip → Trip, receipts → [ReceiptFile]

Trip      name, destination, startDate, endDate, purpose, payments → [Payment]

ReceiptFile  data (external storage), isPDF, addedAt, ocrText, ocrTotal, payment → Payment,
             verification → ReceiptVerification

ReceiptVerification  status (matched | warning | unverified),
          amountResult, timeResult (match | close | mismatch | unread),
          merchantResult (match | weak | mismatch | unread),
          invoice (what the parser read: parsedTotal, parsedDate, parsedTime,
          parsedMerchant, …), source (online | on-device), fallbackReason,
          overriddenByUser, userNote, checkedAt
```

**One container, opened once.** The app and the App Intent share a single
`ModelContainer.shared`. The intent runs inside the app's own process, so a
second container over the same store would hide a newly captured payment from
an Inbox that is already on screen, and would put two coordinators on one
SQLite file. Anything needing a store opens a new `ModelContext` against the
shared container, never a new container. The in-memory variant exists only for
tests.

## 8. Privacy

- Parsing, text recognition and storage all happen on the iPhone. No server, no account.
- Only messages that parse as payments are saved.
- Personal payments are deleted after 30 days.
- Data leaves the phone only when you export and share a report, or, if turned on, through website sync (§11) and the receipt check (§12).

## 9. Known limits

- The Shortcuts automation is a one-time manual setup; iOS gives apps no way to install it.
- A message is only caught if it contains one of the automation keywords. Unusual wording can be pasted in by hand.
- iOS may show a brief "running your automation" banner on some versions.
- Parsing is rule-based; a bank changing its SMS format can reduce payee/reference accuracy until the patterns are updated. The amount and the original SMS are still captured.

## 10. Later

- Email forwarding address for invoices.
- Auto-file rules ("always file Uber during a trip").
- Policy caps (meal per day, hotel per night) with warnings.
- Exchange-rate conversion for foreign card spends.
- iCloud backup and an iPad layout.
- Export straight to Zoho Expense / Concur.

## 11. Website (v0.3)

A read-only web view of the same data, for a laptop at claim time.

- **Hosting:** static files in `docs/`, served by GitHub Pages. No server.
- **Transport:** a private GitHub repo. The phone rewrites `transactions.json`
  there after each change through the contents API; the site reads it with a
  read-only fine-grained token and polls every 30 s (ETag; unchanged costs nothing).
- **Phone side:** off by default. Setup → Website takes owner, repo and a token
  (Contents read & write, that repo only), kept in the Keychain. Sync runs after
  saves (debounced 2 s), inside the Shortcuts action and lock-screen answers
  before they return, and when the app is backgrounded; skipped when the data is
  unchanged.
- **Synced:** all payments (any status) with the original SMS, sender, received
  time and fingerprint; trips. Receipt images are not synced, only their names
  and read totals.
- **Site:** Inbox, work expenses by trip, trips with category totals, all
  payments with search, payment detail with the SMS and an in-browser
  re-check of its fingerprint, and the same claim CSV the phone exports.
- **Not in scope:** answering or editing from the web — the phone stays the
  only writer.

## 12. Receipt check (v0.4)

An attached invoice is verified against its payment — amount, date/time,
merchant. A mismatch is a **warning, never a block**: the user can always
*Add to trip anyway*, and the flag travels with the expense into the proof
section and the export. Build plan: `Travelplan.md`, stages 4–6.

- **Reading:** the phone reads the receipt (Vision, PDFKit) and sends the file
  with that text to the parser service (`invoice-parser/`), which returns the
  fields and a confidence for each. Over 30 s, unreachable, or a total it isn't
  sure of → the phone's reading is used and the receipt is *unverified*.
- **Comparing:** `ReceiptVerifier` applies `VerifierRules`; any mismatch → ⚠
  warning, all match → ✓, close only → ✓ with a note, unread total → ○.
  Parsed values are shown, never written over the payment.
- **Acting:** a banner names each difference and offers *Fix the receipt* or
  *Add to trip anyway* (optional note). A waiting payment with a warning stays
  in the Inbox until one is chosen.
- **Server privacy:** files are processed in memory; nothing about content is
  stored or logged. Per-install signed tokens, rate-limited.
