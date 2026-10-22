import Foundation

enum Money {
    static func string(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        if currency == "INR" { f.locale = Locale(identifier: "en_IN") }
        return f.string(from: value as NSNumber) ?? "\(currency) \(value)"
    }
}
