import Foundation

/// Picks the bill total out of the lines Vision read off a receipt.
///
/// The result is only ever shown as a hint next to the payment — a misread
/// total that silently changed an amount would be worse than no reading at
/// all — so this leans towards saying nothing when the bill is ambiguous.
enum ReceiptTotalReader {

    /// Labels that mark the figure actually paid.
    private static let totalLabels = [
        "grand total", "total amount", "amount payable", "net payable", "net amount",
        "total paid", "amount paid", "bill total", "invoice total", "total due",
        "total", "amount"
    ]

    /// Lines that carry a number which is not the total.
    private static let notTheTotal = [
        "sub total", "subtotal", "sub-total", "taxable", "cgst", "sgst", "igst", "gst",
        "vat", "service charge", "discount", "round off", "rounding", "tip",
        "change", "cash", "balance", "qty", "quantity", "rate", "mrp", "savings"
    ]

    static func total(in lines: [String]) -> Double? {
        var labelled: [Double] = []
        var everything: [Double] = []

        for line in lines {
            let lower = line.lowercased()
            let numbers = amounts(in: line)
            guard !numbers.isEmpty else { continue }
            everything.append(contentsOf: numbers)

            if notTheTotal.contains(where: { lower.contains($0) }) { continue }
            if totalLabels.contains(where: { lower.contains($0) }) {
                labelled.append(contentsOf: numbers)
            }
        }

        // A labelled total beats guessing. Failing that, the largest figure on
        // a bill is almost always what was paid.
        return labelled.max() ?? everything.max()
    }

    static func amounts(in line: String) -> [Double] {
        let pattern = "(?:₹|Rs\\.?|INR)?\\s*"
            + "((?:[0-9]{1,3}(?:,[0-9]{2,3})+|[0-9]+)(?:\\.[0-9]{1,2})?)(?![0-9])"
        return line.matches(of: pattern, caseInsensitive: true).compactMap { match in
            guard let raw = match.groups.first(where: { !$0.isEmpty }),
                  let value = Double(raw.replacingOccurrences(of: ",", with: "")),
                  value >= 1 else { return nil }
            return value
        }
    }
}
