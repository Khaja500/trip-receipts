import SwiftUI

/// Where a notification tap should land. The notification arrives before any
/// view exists, so the destination is parked here and picked up by the tab
/// that owns it.
@Observable
final class Router {
    enum Tab: Hashable { case inbox, expenses, trips, setup }

    var tab: Tab = .inbox
    /// Payment to open on arrival.
    var openPaymentUID: String?
    /// Whether to go straight to the receipt picker once it opens.
    var openReceiptPicker = false

    func showPayment(uid: String, withReceiptPicker: Bool = false) {
        tab = .inbox
        openPaymentUID = uid
        openReceiptPicker = withReceiptPicker
    }

    func clear() {
        openPaymentUID = nil
        openReceiptPicker = false
    }
}
