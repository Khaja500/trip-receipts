import Foundation

/// Runs the sample suite and prints a line per case. Used by
/// `Tools/parser-check.sh`, which needs no Xcode — just the Swift toolchain.
enum ParserCheckRunner {

    @discardableResult
    static func run() -> Bool {
        // Samples carry dates from Oct 2025; freeze "now" so the 45-day window
        // in the date parser behaves the same whenever the suite is run.
        let now = ISO8601DateFormatter().date(from: "2025-10-14T12:00:00Z") ?? .now
        var failures: [String] = []

        for sample in SampleMessages.all {
            let result = SMSParser.parse(sample.text, sender: sample.sender, now: now)
            let problems = check(sample, result)
            if problems.isEmpty {
                print("  ok    \(sample.label)")
            } else {
                print("  FAIL  \(sample.label)")
                for p in problems { print("          \(p)") }
                failures.append(sample.label)
            }
        }

        print("")
        if failures.isEmpty {
            print("\(SampleMessages.all.count) samples, all parsed as expected.")
            return true
        }
        print("\(failures.count) of \(SampleMessages.all.count) failed: \(failures.joined(separator: ", "))")
        return false
    }

    private static func check(_ sample: SampleMessage, _ result: SMSParseResult) -> [String] {
        var problems: [String] = []
        switch (sample.expect, result) {
        case let (.ignored(expected), .ignored(actual)):
            if expected != actual {
                problems.append("ignored for the wrong reason: \(actual.rawValue), wanted \(expected.rawValue)")
            }

        case let (.ignored(expected), .payment(p)):
            problems.append("should have been ignored (\(expected.rawValue)) but parsed as \(p.currency) \(p.amount) to \(p.merchant)")

        case let (.payment(amount, currency, merchant, reference, instrument, direction), .ignored(actual)):
            _ = (currency, merchant, reference, instrument, direction)
            problems.append("should have parsed as \(amount) but was ignored: \(actual.rawValue)")

        case let (.payment(amount, currency, merchant, reference, instrument, direction), .payment(p)):
            if abs(p.amount - amount) > 0.001 { problems.append("amount \(p.amount), wanted \(amount)") }
            if p.currency != currency { problems.append("currency \(p.currency), wanted \(currency)") }
            if let merchant, p.merchant != merchant { problems.append("payee \"\(p.merchant)\", wanted \"\(merchant)\"") }
            if let reference, p.reference != reference { problems.append("reference \(p.reference ?? "nil"), wanted \(reference)") }
            if let instrument, p.instrument != instrument { problems.append("instrument \"\(p.instrument)\", wanted \"\(instrument)\"") }
            if p.direction != direction { problems.append("direction \(p.direction.rawValue), wanted \(direction.rawValue)") }
        }
        return problems
    }
}
