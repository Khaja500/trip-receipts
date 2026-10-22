import Foundation

/// Runs the verifier suite and prints a line per case. Used by
/// `Tools/verifier-check.sh`, which needs no Xcode — just the Swift toolchain.
enum VerifierCheckRunner {

    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []

        for item in VerifierCases.all {
            let result = ReceiptVerifier.verify(item.invoice, against: item.payment,
                                                source: item.source, calendar: VerifierCases.calendar)
            let problems = check(item.expect, result)
            if problems.isEmpty {
                print("  ok    \(item.label)")
            } else {
                print("  FAIL  \(item.label)")
                for p in problems { print("          \(p)") }
                failures.append(item.label)
            }
        }

        print("")
        if failures.isEmpty {
            print("\(VerifierCases.all.count) payment and invoice pairs, all checked as expected.")
            return true
        }
        print("\(failures.count) of \(VerifierCases.all.count) failed.")
        return false
    }

    private static func check(_ expect: VerifierCase.Expectation, _ result: VerificationResult) -> [String] {
        var problems: [String] = []
        if result.status != expect.status {
            problems.append("status \(result.status.rawValue), wanted \(expect.status.rawValue)")
        }
        let fields: [(String, FieldCheck?, FieldCheck)] = [
            ("amount", expect.amount, result.amount),
            ("date/time", expect.time, result.time),
            ("merchant", expect.merchant, result.merchant)
        ]
        for (name, wanted, got) in fields {
            if let wanted, wanted != got {
                problems.append("\(name) \(got.rawValue), wanted \(wanted.rawValue)")
            }
        }
        if let summary = expect.summary {
            let ok = expect.exactSummary ? result.summary == summary : result.summary.contains(summary)
            if !ok {
                problems.append("summary \"\(result.summary)\", wanted \(expect.exactSummary ? "" : "it to contain ")\"\(summary)\"")
            }
        }
        if !problems.isEmpty, !result.summary.isEmpty, expect.summary == nil {
            problems.append("summary was \"\(result.summary)\"")
        }
        return problems
    }
}
