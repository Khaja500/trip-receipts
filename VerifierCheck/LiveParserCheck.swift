import Foundation

/// Sends real receipt files through the app's `InvoiceParseClient` to a
/// running parser, then judges the answer with `ReceiptVerifier` — the path a
/// receipt takes in the app, minus the camera. Run by `Tools/receipt-check.sh`,
/// which starts the server.
enum LiveParserCheck {

    /// Keeps the token in memory, so the check never touches the Keychain.
    final class MemoryTokens: TokenStore {
        var token: String?
        init(_ token: String? = nil) { self.token = token }
        func read() -> String? { token }
        func save(_ value: String) { token = value }
        func delete() { token = nil }
    }

    struct Case {
        var label: String
        var file: String
        var phoneText: String? = nil
        var payment: ReceiptVerifier.PaymentSide
        var expect: VerificationStatus
        var summary: String? = nil
    }

    static func run(server: URL, silent: URL, fixtures: URL) async -> Bool {
        var failures = 0
        func report(_ label: String, _ problems: [String]) {
            if problems.isEmpty {
                print("  ok    \(label)")
            } else {
                print("  FAIL  \(label)")
                problems.forEach { print("          \($0)") }
                failures += 1
            }
        }

        let tokens = MemoryTokens()
        let client = InvoiceParseClient(server: server, tokens: tokens)
        let cases = [
            Case(label: "Uber PDF, same total and time → verified",
                 file: "uber_ride_pdf.pdf",
                 payment: VerifierCases.paid(486, to: "UBER INDIA", at: "2025-10-12 09:41"),
                 expect: .matched),
            Case(label: "Uber PDF, ₹842 from 3 Oct against ₹1,250 on 9 Oct → warning naming both",
                 file: "uber_ride_old.pdf",
                 payment: VerifierCases.paid(1250, to: "UBER INDIA", at: "2025-10-09 18:00"),
                 expect: .warning,
                 summary: "Invoice total ₹842 vs payment ₹1,250; invoice dated 3 Oct vs payment 9 Oct"),
            Case(label: "restaurant PDF with a tip on the card → verified, with a note",
                 file: "udupi_bill.pdf",
                 payment: VerifierCases.paid(380, to: "GREEN LEAF UDUPI", at: "2025-10-14 13:31"),
                 expect: .matched,
                 summary: "Payment is ₹33 (10%) more than the invoice"),
            Case(label: "photo of a parking slip, with the phone's own text → verified",
                 file: "parking_photo.png",
                 phoneText: try? String(contentsOf: fixtures.appendingPathComponent("parking_photo.client.txt"),
                                        encoding: .utf8),
                 payment: VerifierCases.paid(120, to: "CITY CENTRE PARKING", at: "2025-10-12 13:41"),
                 expect: .matched),
            Case(label: "the right receipt on the wrong payment → warning",
                 file: "udupi_bill.pdf",
                 payment: VerifierCases.paid(347, to: "UBER INDIA", at: "2025-10-14 13:31"),
                 expect: .warning,
                 summary: "Invoice from GREEN LEAF UDUPI RESTAURANT vs payment to UBER INDIA")
        ]

        for item in cases {
            guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(item.file)) else {
                report(item.label, ["fixture \(item.file) missing"])
                continue
            }
            do {
                let invoice = try await client.parse(data, filename: item.file, text: item.phoneText,
                                                     hints: .init(item.payment))
                let result = ReceiptVerifier.verify(invoice, against: item.payment, source: .online,
                                                    calendar: VerifierCases.calendar)
                var problems: [String] = []
                if result.status != item.expect {
                    problems.append("status \(result.status.rawValue), wanted \(item.expect.rawValue): \(result.summary)")
                }
                if let summary = item.summary, !result.summary.contains(summary) {
                    problems.append("summary \"\(result.summary)\", wanted it to contain \"\(summary)\"")
                }
                report(item.label, problems)
            } catch {
                report(item.label, ["parse failed: \(error.localizedDescription)"])
            }
        }

        // A server restart forgets every token; the client registers again.
        let stale = MemoryTokens("tr1.forgotten.1700000000.00000000000000000000000000000000")
        let pdf = (try? Data(contentsOf: fixtures.appendingPathComponent("uber_ride_pdf.pdf"))) ?? Data()
        do {
            _ = try await InvoiceParseClient(server: server, tokens: stale)
                .parse(pdf, filename: "uber.pdf", text: nil, hints: nil)
            report("a forgotten token is replaced and the receipt still parsed",
                   stale.token?.contains("forgotten") == false ? [] : ["kept the stale token"])
        } catch {
            report("a forgotten token is replaced and the receipt still parsed", ["\(error.localizedDescription)"])
        }

        // Server off: the app falls back to the phone's reading, unverified.
        let payment = VerifierCases.paid(486, to: "UBER INDIA", at: "2025-10-12 09:41")
        let down = InvoiceParseClient(server: URL(string: "http://127.0.0.1:9")!, tokens: MemoryTokens())
        await expectFallback("server off → unverified, never a warning", client: down, pdf: pdf,
                             payment: payment, report: report) {
            if case .unreachable = $0 { return true } else { return false }
        }

        // A server that never answers: cut off at the timeout.
        var slow = InvoiceParseClient(server: silent, tokens: MemoryTokens("tr1.x.1.0"))
        slow.timeout = 2
        await expectFallback("server silent past the timeout → unverified", client: slow, pdf: pdf,
                             payment: payment, report: report) { $0 == .timedOut }

        print("")
        if failures == 0 {
            print("Receipts sent through the client and server were judged as expected.")
            return true
        }
        print("\(failures) end-to-end checks failed.")
        return false
    }

    /// What `ReceiptCheck` does when the client throws: the phone's reading
    /// (here, a total of ₹842 that would otherwise be a mismatch) stands in.
    private static func expectFallback(
        _ label: String, client: InvoiceParseClient, pdf: Data,
        payment: ReceiptVerifier.PaymentSide,
        report: (String, [String]) -> Void, expected: (InvoiceParseError) -> Bool
    ) async {
        do {
            _ = try await client.parse(pdf, filename: "uber.pdf", text: nil, hints: .init(payment))
            report(label, ["the parse succeeded"])
        } catch let error as InvoiceParseError {
            let onDevice = ParsedInvoice(total: 842)
            let result = ReceiptVerifier.verify(onDevice, against: payment, source: .onDevice,
                                                calendar: VerifierCases.calendar)
            var problems: [String] = []
            if !expected(error) { problems.append("unexpected error \(error)") }
            if result.status != .unverified { problems.append("status \(result.status.rawValue)") }
            report(label + " (\(error.localizedDescription))", problems)
        } catch {
            report(label, ["unexpected error \(error)"])
        }
    }
}
