import Foundation

/// What a bank SMS turned into. `nil` from the parser means "not a payment,
/// don't store it".
struct ParsedPayment: Equatable {
    var amount: Double
    var currency: String
    var merchant: String
    var instrument: String
    var reference: String?
    var bank: String?
    var paidAt: Date?
    var direction: Direction
    var confidence: Double

    enum Direction: String, Equatable {
        case debit, refund
    }
}

/// Why a message was not turned into a payment. Useful in Setup → paste-in,
/// so a miss can be explained rather than silently dropped.
enum ParseRejection: String, Equatable {
    case otp = "Looks like an OTP"
    case request = "A payment request, not a payment"
    case failed = "A failed or declined payment"
    case upcoming = "An upcoming or due payment"
    case credit = "Money received, not spent"
    case promo = "Promotional message"
    case balance = "A balance or statement update"
    case noAmount = "No amount found"
    case noDebitWord = "Nothing here says money went out"
}

enum SMSParseResult: Equatable {
    case payment(ParsedPayment)
    case ignored(ParseRejection)
}

/// Rule-based parser for Indian bank, card and UPI messages.
///
/// Every pattern lives in this one file so a bank changing its wording is a
/// single-file fix. Misread real messages go into `SampleMessages.swift`.
enum SMSParser {

    static func parse(_ raw: String, sender: String = "", now: Date = .now) -> SMSParseResult {
        let text = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        let lower = text.lowercased()

        if let rejection = ignoreReason(lower) { return .ignored(rejection) }

        let direction: ParsedPayment.Direction = isRefund(lower) ? .refund : .debit
        if direction == .debit, !hasDebitWord(lower) { return .ignored(.noDebitWord) }

        guard let (amount, currency) = amountAndCurrency(in: text) else {
            return .ignored(.noAmount)
        }

        let merchant = payee(in: text) ?? ""
        let instrument = instrumentDescription(in: text)
        let ref = reference(in: text)
        let bankName = bank(in: text, sender: sender)
        let date = paymentDate(in: text, now: now)

        // Confidence: amount is a given at this point; the rest is what we add.
        var score = 0.4
        if !merchant.isEmpty { score += 0.25 }
        if !instrument.isEmpty { score += 0.15 }
        if ref != nil { score += 0.1 }
        if bankName != nil { score += 0.1 }

        return .payment(ParsedPayment(
            amount: amount,
            currency: currency,
            merchant: merchant.isEmpty ? "Unknown payee" : merchant,
            instrument: instrument,
            reference: ref,
            bank: bankName,
            paidAt: date,
            direction: direction,
            confidence: min(1, score)
        ))
    }

    // MARK: - Ignore rules

    private static func ignoreReason(_ lower: String) -> ParseRejection? {
        if lower.contains("otp") || lower.contains("one time password")
            || lower.contains("one-time password") || lower.contains("verification code") {
            return .otp
        }
        if lower.contains("has requested") || lower.contains("is requesting")
            || lower.contains("payment request") || lower.contains("collect request")
            || lower.contains("requesting money") {
            return .request
        }
        for word in ["failed", "declined", "unsuccessful", "could not be processed",
                     "not processed", "transaction cancelled", "has been cancelled"]
        where lower.contains(word) {
            return .failed
        }
        // Upcoming / mandate — "will be debited", "due on", autopay notices.
        for word in ["will be debited", "will be deducted", "is due", "due on", "due date",
                     "autopay", "auto pay", "e-mandate", "emandate", "mandate", "standing instruction",
                     "scheduled for", "reminder:", "payment reminder"]
        where lower.contains(word) {
            return .upcoming
        }
        if isRefund(lower) { return nil }  // refunds are credits we do want
        for word in ["credited to your", "has been credited", "is credited to",
                     "received in your", "deposited to", "money received"]
        where lower.contains(word) {
            return .credit
        }
        for word in ["pre-approved", "preapproved", "apply now", "click here", "offer ends",
                     "limited period", "lowest interest", "personal loan", "win ", "congratulations",
                     "unsubscribe", "download the app", "t&c apply"]
        where lower.contains(word) {
            return .promo
        }
        // Balance / statement pings carry an amount but no payment.
        if (lower.contains("avl bal") || lower.contains("available balance")
            || lower.contains("statement") || lower.contains("min amt due"))
            && !hasDebitWord(lower) {
            return .balance
        }
        return nil
    }

    private static func isRefund(_ lower: String) -> Bool {
        for word in ["refund", "reversal", "reversed", "returned to your", "has been credited back"]
        where lower.contains(word) {
            return true
        }
        return false
    }

    private static func hasDebitWord(_ lower: String) -> Bool {
        for word in ["debited", "debit", "spent", "paid", " sent ", "withdrawn", "withdrawal",
                     "transferred", "txn of", "purchase of", "charged", "used for a transaction",
                     "transaction of", "has been used for"]
        where lower.contains(word) {
            return true
        }
        return lower.hasPrefix("sent ")
    }

    // MARK: - Amount

    private static let currencyCodes = ["INR", "USD", "EUR", "GBP", "AED", "SGD", "AUD",
                                        "CAD", "JPY", "CHF", "THB", "MYR", "LKR", "NPR"]

    private static let symbolToCode: [String: String] = [
        "₹": "INR", "रू": "INR", "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY"
    ]

    /// Picks the payment amount, skipping anything that follows a balance or
    /// limit label.
    static func amountAndCurrency(in text: String) -> (Double, String)? {
        let codes = (currencyCodes + ["Rs\\.?", "RS\\.?", "rs\\.?"]).joined(separator: "|")
        let symbols = "₹|\\$|€|£|¥"
        // Comma-grouped first, so "1,250.00" is not clipped to "1"; then a plain
        // run of digits, so "1250.00" is not clipped to "125".
        let number = "((?:[0-9]{1,3}(?:,[0-9]{2,3})+|[0-9]+)(?:\\.[0-9]{1,2})?)(?![0-9])"
        let patterns = [
            "(?:(\(codes))|(\(symbols)))\\s*\(number)",
            "\(number)\\s*(?:(\(codes))|(\(symbols)))"
        ]

        if let found = firstAmount(in: text, patterns: patterns, defaultCode: nil) {
            return found
        }
        // Some banks drop the currency entirely: "debited by 150.0 on date...".
        let bare = ["(?:debited|credited|spent|paid|sent|withdrawn|charged)\\s+(?:by|for|of|with)\\s+\(number)"]
        return firstAmount(in: text, patterns: bare, defaultCode: "INR", caseInsensitive: true)
    }

    /// Earliest amount in the message that is not sitting behind a balance or
    /// limit label — that one is the payment.
    private static func firstAmount(
        in text: String,
        patterns: [String],
        defaultCode: String?,
        caseInsensitive: Bool = false
    ) -> (Double, String)? {
        var best: (value: Double, code: String, location: Int)?
        for pattern in patterns {
            for m in text.matches(of: pattern, caseInsensitive: caseInsensitive) {
                guard let range = m.range else { continue }
                if isBalanceContext(text, before: range.lowerBound) { continue }
                let groups = m.groups
                guard let numberString = groups.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }),
                      let value = Double(numberString.replacingOccurrences(of: ",", with: "")),
                      value > 0 else { continue }
                let tag = groups.first { $0.rangeOfCharacter(from: .decimalDigits) == nil && !$0.isEmpty }
                let code = tag.map(normaliseCurrency) ?? defaultCode ?? "INR"
                let location = text.distance(from: text.startIndex, to: range.lowerBound)
                if best == nil || location < best!.location {
                    best = (value, code, location)
                }
            }
        }
        guard let best else { return nil }
        return (best.value, best.code)
    }

    private static func normaliseCurrency(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let code = symbolToCode[trimmed] { return code }
        let upper = trimmed.uppercased()
        if upper == "RS" || upper == "INR" { return "INR" }
        return currencyCodes.contains(upper) ? upper : "INR"
    }

    /// True when the 28 characters before an amount mention a balance or limit.
    private static func isBalanceContext(_ text: String, before index: String.Index) -> Bool {
        let start = text.index(index, offsetBy: -28, limitedBy: text.startIndex) ?? text.startIndex
        let window = text[start..<index].lowercased()
        for word in ["avl bal", "avbl bal", "available bal", "bal:", "balance", "limit",
                     "avl lmt", "available credit", "outstanding", "min amt", "total due"]
        where window.contains(word) {
            return true
        }
        return false
    }

    // MARK: - Payee

    /// A payee name runs until the message moves on — "on 12-10-25", "has been
    /// credited back", a full stop or a comma. `payeeEnd` is that boundary, and
    /// keeping it in one place is what stops a name swallowing half the SMS.
    private static let payeeEnd =
        "(?=\\s+(?:on|has|have|is|was|were|via|ref|refno|using|towards|dated|at|from|not)\\b|[.,;]|\\s*$)"

    private static let payeePatterns = [
        // Axis / PhonePe style: UPI/P2M/412345678901/UBER INDIA
        "UPI/P2[MA]/[A-Za-z0-9]+/([A-Za-z0-9 &_'-]{2,40})",
        // ICICI: "...debited for Rs 486 on 12-Oct-25; UBER INDIA credited."
        ";\\s*([A-Za-z0-9 &._'-]{2,40}?)\\s+credited",
        // HDFC: "...VPA uber@axisbank (UBER INDIA)"
        "VPA\\s+[A-Za-z0-9._-]+@[A-Za-z]+\\s*\\(([^)]{2,40})\\)",
        // Card: "...spent on Card XX1234 at MAKEMYTRIP on 12-Oct-25"
        "\\bat\\s+([A-Za-z0-9 &._'*-]{2,40}?)" + payeeEnd,
        // UPI / transfer: "paid to SWIGGY", "trf to RAHUL", "to vpa@okaxis"
        "\\b(?:to|towards)\\s+(?:VPA\\s+)?([A-Za-z0-9 &._'@-]{2,40}?)" + payeeEnd,
        "\\bInfo:\\s*([A-Za-z0-9 &._*-]{2,40}?)" + payeeEnd
    ]

    private static let payeeNoise: Set<String> = [
        "your account", "your a/c", "your card", "account", "a/c", "card", "bank",
        "vpa", "upi", "the", "you", "us", "pay", "self"
    ]

    static func payee(in text: String) -> String? {
        for pattern in payeePatterns {
            guard let m = text.matches(of: pattern, caseInsensitive: true).first,
                  let candidate = m.groups.first(where: { !$0.isEmpty }) else { continue }
            let cleaned = cleanPayee(candidate)
            if cleaned.count >= 2, !payeeNoise.contains(cleaned.lowercased()) {
                return cleaned
            }
        }
        return nil
    }

    private static func cleanPayee(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:-_*"))
        // Drop a trailing reference blob that got swept in.
        s = s.replacingOccurrences(of: "\\s+(?:Ref|RRN|UTR|UPI)\\b.*$", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        // A bare VPA reads better as its handle.
        if s.contains("@"), let handle = s.split(separator: "@").first, handle.count >= 3 {
            s = String(handle)
        }
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        // Bank text is shouty or all-lowercase; title-case either.
        if s == s.uppercased() || s == s.lowercased(), s.count > 3 {
            s = s.capitalized
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Instrument

    static func instrumentDescription(in text: String) -> String {
        let lower = text.lowercased()
        var parts: [String] = []

        if lower.contains("upi") || looksLikeUPI(text) { parts.append("UPI") }
        else if lower.contains("neft") { parts.append("NEFT") }
        else if lower.contains("imps") { parts.append("IMPS") }
        else if lower.contains("rtgs") { parts.append("RTGS") }
        else if lower.contains("wallet") { parts.append("Wallet") }

        if let card = lastFour(in: text, patterns: [
            "(?:credit|debit)?\\s*card\\s*(?:no\\.?|ending in|ending|xx|x+)?\\s*[Xx*•]*([0-9]{3,6})\\b",
            "card\\s+[Xx*•]+([0-9]{3,6})"
        ]) {
            parts.append("Card ••\(card)")
        } else if let account = lastFour(in: text, patterns: [
            "\\b(?:account|acct|a/c|ac)\\s*(?:no\\.?|ending in|ending)?\\s*[Xx*•]*([0-9]{3,6})\\b",
            "\\b(?:account|acct|a/c|ac)\\s+[Xx*•]+([0-9]{3,6})"
        ]) {
            parts.append("A/c ••\(account)")
        }

        return parts.joined(separator: " · ")
    }

    /// The masked tail of a card or account — usually four digits, but some
    /// banks print three or six.
    /// HDFC's UPI message never says "UPI": it is "Sent Rs.X From A/C y To Z
    /// Ref <12 digits>". That shape, with no card in sight, is a UPI payment.
    private static func looksLikeUPI(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.contains("card") else { return false }
        guard lower.contains("sent ") || lower.contains("trf to") else { return false }
        guard let ref = reference(in: text) else { return false }
        return ref.count == 12 && ref.allSatisfy(\.isNumber)
    }

    private static func lastFour(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let m = text.matches(of: pattern, caseInsensitive: true).first,
               let digits = m.groups.first(where: { $0.count >= 3 }) {
                return digits
            }
        }
        return nil
    }

    // MARK: - Reference

    private static let referencePatterns = [
        "UPI\\s*(?:Ref(?:erence)?)?\\s*(?:No\\.?|ID)?\\s*[:.\\- ]\\s*([0-9]{6,20})",
        "\\bRRN\\s*[:.\\- ]?\\s*([A-Za-z0-9]{6,20})",
        "\\bUTR\\s*(?:No\\.?)?\\s*[:.\\- ]?\\s*([A-Za-z0-9]{6,22})",
        "\\bRef(?:erence)?\\s*(?:No\\.?|#)?\\s*[:.\\- ]\\s*([A-Za-z0-9]{6,20})",
        "\\bTxn\\s*(?:ID|No\\.?)\\s*[:.\\- ]?\\s*([A-Za-z0-9]{6,20})",
        "UPI/P2[MA]/([0-9]{6,20})/"
    ]

    static func reference(in text: String) -> String? {
        for pattern in referencePatterns {
            if let m = text.matches(of: pattern, caseInsensitive: true).first,
               let value = m.groups.first(where: { !$0.isEmpty }) {
                return value
            }
        }
        return nil
    }

    // MARK: - Bank

    private static let banks: [(needle: String, name: String)] = [
        ("hdfc", "HDFC Bank"), ("icici", "ICICI Bank"), ("sbi", "SBI"),
        ("state bank", "SBI"), ("axis", "Axis Bank"), ("kotak", "Kotak"),
        ("idfc", "IDFC FIRST"), ("yes bank", "Yes Bank"), ("indusind", "IndusInd"),
        ("rbl", "RBL Bank"), ("federal", "Federal Bank"), ("canara", "Canara Bank"),
        ("punjab national", "PNB"), ("pnb", "PNB"), ("bob", "Bank of Baroda"),
        ("bank of baroda", "Bank of Baroda"), ("amex", "American Express"),
        ("american express", "American Express"), ("onecard", "OneCard"),
        ("au small", "AU Bank"), ("au bank", "AU Bank"), ("paytm", "Paytm"),
        ("airtel", "Airtel Payments Bank")
    ]

    static func bank(in text: String, sender: String) -> String? {
        let haystack = (sender + " " + text).lowercased()
        for (needle, name) in banks where haystack.contains(needle) { return name }
        return nil
    }

    // MARK: - Date

    private static let dateFormats = [
        "dd/MM/yy", "dd/MM/yyyy", "dd-MM-yy", "dd-MM-yyyy",
        "dd-MMM-yy", "dd-MMM-yyyy", "dd MMM yy", "dd MMM yyyy",
        "ddMMMyy", "ddMMMyyyy", "yyyy-MM-dd"
    ]

    private static let datePatterns = [
        "\\b([0-9]{1,2}[/-][0-9]{1,2}[/-][0-9]{2,4})\\b",
        "\\b([0-9]{1,2}-[A-Za-z]{3}-[0-9]{2,4})\\b",
        "\\b([0-9]{1,2}\\s[A-Za-z]{3}\\s[0-9]{2,4})\\b",
        "\\b([0-9]{1,2}[A-Za-z]{3}[0-9]{2,4})\\b",
        "\\b([0-9]{4}-[0-9]{2}-[0-9]{2})\\b"
    ]

    /// Only trusted when it lands within the last 45 days; otherwise the
    /// caller falls back to when the SMS arrived.
    static func paymentDate(in text: String, now: Date = .now) -> Date? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: now) ?? now
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now

        for pattern in datePatterns {
            for m in text.matches(of: pattern) {
                guard let token = m.groups.first(where: { !$0.isEmpty }) else { continue }
                for format in dateFormats {
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.timeZone = .current
                    f.dateFormat = format
                    guard let date = f.date(from: token) else { continue }
                    if date >= cutoff && date <= tomorrow { return date }
                }
            }
        }
        return nil
    }
}

// MARK: - Small regex helper

/// NSRegularExpression wrapped in something readable. Kept private to the
/// parser so the rest of the app never touches NSRange.
struct RegexMatch {
    var range: Range<String.Index>?
    var groups: [String]
}

extension String {
    func matches(of pattern: String, caseInsensitive: Bool = false) -> [RegexMatch] {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let full = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: full).map { result in
            var groups: [String] = []
            for i in 1..<result.numberOfRanges {
                if let r = Range(result.range(at: i), in: self) {
                    groups.append(String(self[r]))
                } else {
                    groups.append("")
                }
            }
            return RegexMatch(range: Range(result.range, in: self), groups: groups)
        }
    }
}
