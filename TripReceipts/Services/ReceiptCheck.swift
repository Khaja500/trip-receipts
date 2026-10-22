import Foundation

/// Reads a newly attached receipt for checking against its payment: the
/// online parser first, the phone's own reading when the server can't help.
/// Attaching never fails because of the server — at worst the receipt is
/// marked unverified.
enum ReceiptCheck {

    struct Outcome {
        /// The phone's own reading, kept on the receipt either way.
        var reading: ReceiptOCR.Reading
        var invoice: ParsedInvoice
        var source: VerificationSource
        var fallbackReason: String?
    }

    static func run(data: Data, isPDF: Bool, filename: String,
                    for payment: ReceiptVerifier.PaymentSide) async -> Outcome {
        // The phone reads first: its text goes up with the file, and it is
        // the answer if the server can't give one.
        let reading = await ReceiptOCR.read(data: data, isPDF: isPDF)

        guard let client = InvoiceParseClient.configured() else {
            return fallback(reading, reason: "No parser server is set in Setup.")
        }
        do {
            let invoice = try await client.parse(data, filename: filename, text: reading.text,
                                                 hints: .init(payment))
            guard invoice.readTotal != nil else {
                return fallback(reading, reason: "The parser couldn't read the total with confidence.")
            }
            return Outcome(reading: reading, invoice: invoice, source: .online)
        } catch {
            return fallback(reading, reason: error.localizedDescription)
        }
    }

    private static func fallback(_ reading: ReceiptOCR.Reading, reason: String) -> Outcome {
        Outcome(reading: reading, invoice: ParsedInvoice(total: reading.total),
                source: .onDevice, fallbackReason: reason)
    }
}

extension InvoiceParseClient {
    /// The server saved in Setup, with its token in the Keychain.
    static func configured(defaults: UserDefaults = .standard) -> InvoiceParseClient? {
        guard let url = serverURL(from: defaults.string(forKey: serverKey) ?? "") else { return nil }
        return InvoiceParseClient(
            server: url,
            tokens: KeychainItem(service: "TripReceipts.InvoiceParser", account: url.absoluteString)
        )
    }
}
