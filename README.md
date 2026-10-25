# Trip Receipts

A listening inbox for work-travel payments. Every outgoing payment SMS is
caught the moment it arrives and turned into one question — *was this for work
travel?* — answerable from the lock screen. A "yes" becomes an expense carrying
the original bank message as proof of payment, with the bill attached, filed
under the trip it belongs to, and exportable as a reimbursement pack.

Built to `Travelspec.md` and `Travelplan.md`. iPhone, iOS 17+, SwiftUI +
SwiftData, no server and no third-party packages.

**Website:** <https://khaja500.github.io/trip-receipts/> shows the same
payments on any screen, live, once sync is turned on — see [Website](#website).

#The private repo is :Khaja500/trip-receipts-shared
#The Read only token is : AQ.Ab8RN6K1CTC8sMOUVN_U3SaiddYwUscqUqAsr-bdWmgX9422Qg

## Opening it

```
open TripReceipts.xcodeproj
```

Pick your Apple ID under *Signing & Capabilities* (the team is intentionally
left blank), then run on your iPhone. The simulator works for everything
except the document camera.

## The five automations

iOS gives no app access to SMS, and no way to install a personal automation —
so this is the one manual step. In Shortcuts → Automation → New → Message:

| | |
|---|---|
| Trigger | **Message Contains** one of `debited`, `spent`, `sent`, `paid`, `withdrawn`. Leave the sender empty. |
| Timing | **Run Immediately**, with **Notify When Run** off — this is what makes it silent. |
| Action | **Trip Receipts → Check Payment Message**, with *Message* set to **Shortcut Input**. |

One automation per keyword, five in total. A message caught by two of them is
recognised as the same payment and asked about once. The Setup tab lists the
keywords and has a *Send a test payment* button that runs the whole path —
parse, store, ask — so you can answer a real notification from the lock screen.

## Checking it without Xcode

Both scripts build with the plain Swift toolchain and run on the Mac:

```
./Tools/parser-check.sh    # 20 sample bank messages → expected parse
./Tools/rules-check.sh     # 20 rules: duplicates, refunds, trips, retention, receipts, proof
```

`Tools/parser-check.sh` is the one to run after touching any pattern in
`SMSParser.swift`. When a real message is misread, add it to
`ParserCheck/SampleMessages.swift` with what it should have produced *before*
changing the patterns.

## Layout

```
TripReceipts/
  App/        entry point, shared ModelContainer, Router, notification actions
  Intents/    CheckPaymentMessageIntent — what Shortcuts calls
  Models/     Payment, Trip, ReceiptFile, ExpenseCategory
  Services/   SMSParser, MatchingRules, PaymentStore, NotificationManager,
              ReceiptOCR, ReceiptTotalReader, ReportBuilder, ProofHasher,
              CategoryGuesser
  Views/      Inbox, Expenses, Trips, Setup, PaymentDetail, AddPayment, Receipts
ParserCheck/  sample messages and the two check suites
Tools/        the scripts that run them
docs/         the website (GitHub Pages): index.html, app.js, styles.css, sample.json
```

`Services/GitHubSync.swift` (when and where to upload) and
`Services/SyncSnapshot.swift` (what goes up) are the phone's half of the
website.

The rules worth being careful about — what counts as a duplicate, which
payment a refund belongs to, which dates a trip claims, how long a personal
payment is kept — live in `MatchingRules.swift` and `ReceiptTotalReader.swift`
as plain functions over plain values, separately from storage. That is what
lets both suites run without Xcode, a simulator, or a device.

## How a payment moves

```
SMS → Shortcuts automation → CheckPaymentMessageIntent
    → ignore OTPs, requests, failures, upcoming debits, credits, promos
    → parse amount, payee, method, reference, date, bank
    → duplicate? keep the extra text as more proof, don't ask twice
    → refund? reduce the claim on the original payment and say so
    → otherwise store as pending and ask

Yes, work travel      → filed to the trip covering that date, receipt offered
Work – add receipt    → opens on that payment with the receipt picker
Personal              → out of the inbox, kept 30 days so it can be undone
No answer             → stays in the Inbox; a 9 pm reminder if any are waiting
```

## Proof of payment

The original message is stored exactly as it arrived, with its sender and
received time, and a SHA-256 fingerprint taken at that moment. Nothing in the
app rewrites it. The payment screen shows whether the stored text still matches
its fingerprint, and the exported PDF prints both the message and the
fingerprint on the expense's page. Where the bank and the UPI app both sent a
message, the second is kept alongside the first.

## Export

Trips → a trip → *Export claim pack* produces:

- **PDF** — summary and category totals, line items, then a page per expense
  with its details, the original message, the fingerprint, and the receipt
  images (PDF invoices rendered page by page).
- **CSV** — a row per expense including reference, method, receipt count, the
  original message and the fingerprint.

Both go through the iOS share sheet.

## Website

`docs/` is a static site, served by GitHub Pages from this repo, that shows
what the phone has caught: the Inbox still waiting for an answer, work
expenses by trip, missing receipts, every payment, and each original SMS with
its fingerprint re-checked in the browser. It downloads the same claim CSV the
phone exports.

There is no server. The phone writes, the site reads, and a private repo sits
in between:

```
SMS → app (as above) → saves → GitHubSync
    → transactions.json in a private repo   (one file, rewritten whole, one commit per change)
    ← website polls every 30 s with a read-only token (unchanged = free 304)
```

Setting it up, once:

1. **A private repo** for the data, e.g. `trip-receipts-data`. Keep it private.
2. **Two fine-grained tokens** (GitHub → Settings → Developer settings →
   Fine-grained tokens), each with *Repository access: only that repo*:
   - phone — *Contents: Read and write*
   - website — *Contents: Read-only*
3. **Phone:** Setup → Website → turn on, enter owner, repo and the phone token →
   *Save and sync now*. The line under it says when it last synced, or what
   went wrong.
4. **Website:** open it (Setup has an *Open the website* link that fills in the
   repo), paste the website token.

When it syncs: after every save in the app, two seconds later so a bulk
"mark all" is one commit; before the Shortcuts action returns, so a payment
caught on a locked phone goes up straight away; after a lock-screen answer; and
when the app leaves the foreground. An upload is skipped when nothing changed.

What goes up: every payment the app holds — waiting, work and personal — with
its original SMS, sender, fingerprint, category, trip and notes, plus the
trips. Receipt **images stay on the phone**; only their file names and the total
read from them are synced.

The phone token lives in the Keychain (readable after first unlock, so a locked
phone can still sync, and never backed up). The website token lives in that
browser only, and is sent only to `api.github.com`; the page's
Content-Security-Policy blocks any other destination.

`docs/sample.json` is invented data in the exact synced shape, with real
fingerprints; *Look around with sample data* on the site loads it.

## Privacy

Parsing, text recognition and storage all happen on the iPhone. There is no
server and no account. Only messages that parse as payments are stored — OTPs
and non-payment texts are discarded, never written down. Personal payments are
deleted 30 days after you mark them. With website sync off, data leaves the
phone only when you export and share a report.

With website sync on, the payments and trips — including the original SMS
text — are also copied to the private repo you chose. Every sync is a commit,
so the repo's history keeps older snapshots, including personal payments the
phone has since deleted. Deleting that repo removes all of it.

## Known limits

Carried over from the spec, and still true:

- The Shortcuts automations are a one-time manual setup.
- A message is only caught if it contains one of the five keywords. Anything
  else can be pasted into the app by hand.
- iOS shows a brief "running your automation" banner on some versions.
- Parsing is rule-based. A bank changing its SMS format can degrade the payee
  or reference until the patterns are updated — the amount and the original
  message are still captured, and every pattern is in one file.
- A free Apple ID signs the app for 7 days; a paid account for a year.
- The website is read-only. Answering, receipts and trips are done on the phone.
- Website sync needs the phone online when it runs; a failed upload is retried
  on the next change or the next time the app is left.
- Fine-grained tokens expire (you pick when). The phone's Setup and the
  website both say so when GitHub refuses one.
