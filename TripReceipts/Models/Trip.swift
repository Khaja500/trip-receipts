import Foundation
import SwiftData

@Model
final class Trip {
    var name: String = ""
    var destination: String = ""
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var purpose: String = ""
    var client: String = ""
    var costCentre: String = ""
    var createdAt: Date = Date.now

    @Relationship(inverse: \Payment.trip)
    var payments: [Payment] = []

    init(
        name: String,
        destination: String = "",
        startDate: Date,
        endDate: Date,
        purpose: String = "",
        client: String = "",
        costCentre: String = ""
    ) {
        self.name = name
        self.destination = destination
        self.startDate = startDate
        self.endDate = endDate
        self.purpose = purpose
        self.client = client
        self.costCentre = costCentre
        self.createdAt = .now
    }

    /// The dates this trip claims — see `TripWindow` for the margins.
    var filingWindow: ClosedRange<Date> {
        TripWindow.range(start: startDate, end: endDate)
    }

    func covers(_ date: Date) -> Bool { filingWindow.contains(date) }

    var isActive: Bool { covers(.now) }

    var workPayments: [Payment] { payments.filter { $0.status == .work } }

    var total: Double { workPayments.reduce(0) { $0 + $1.netClaimable } }

    var missingReceiptCount: Int { workPayments.filter { !$0.hasReceipt }.count }

    var currency: String { workPayments.first?.currency ?? "INR" }

    var formattedTotal: String { Money.string(total, currency: currency) }

    var dateRangeText: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        let end = DateFormatter()
        end.dateFormat = "d MMM yyyy"
        return "\(f.string(from: startDate)) – \(end.string(from: endDate))"
    }

    func totalsByCategory() -> [(ExpenseCategory, Double)] {
        var sums: [ExpenseCategory: Double] = [:]
        for p in workPayments { sums[p.category, default: 0] += p.netClaimable }
        return sums.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}
