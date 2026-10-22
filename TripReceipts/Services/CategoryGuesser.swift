import Foundation

/// Guesses a category from the payee. Always editable afterwards — a wrong
/// guess costs a tap, so the list leans towards recognising travel.
enum CategoryGuesser {

    private static let rules: [(needles: [String], category: ExpenseCategory)] = [
        (["indigo", "air india", "vistara", "spicejet", "akasa", "emirates", "lufthansa",
          "qatar airways", "singapore air", "airasia", "goair", "flight"], .airfare),
        (["irctc", "railway", "rail", "ixigo train", "confirmtkt", "railyatri"], .rail),
        (["uber", "ola", "rapido", "meru", "blusmart", "taxi", "cab", "savaari"], .cab),
        (["bmtc", "best ", "dmrc", "metro", "bmrcl", "redbus", "abhibus", "ksrtc",
          "msrtc", "chalo", "namma yatri", "bus"], .localTransport),
        (["oyo", "taj", "marriott", "hyatt", "radisson", "lemon tree", "ibis", "novotel",
          "treebo", "fabhotel", "hotel", "resort", "makemytrip", "goibibo", "booking.com",
          "agoda", "airbnb", "cleartrip", "yatra", "easemytrip"], .hotel),
        (["swiggy", "zomato", "dominos", "starbucks", "cafe", "restaurant", "barbeque",
          "haldiram", "mcdonald", "kfc", "pizza", "eatfit", "chaayos", "bakery"], .meals),
        (["hpcl", "iocl", "bpcl", "indian oil", "shell", "reliance petro", "fuel", "petrol",
          "jio-bp", "nayara"], .fuel),
        (["fastag", "toll", "parking", "nhai", "paytm fastag", "park+"], .tollsParking),
        (["visa fee", "vfs", "forex", "thomas cook", "bookmyforex", "niyo", "embassy"], .visaForex)
    ]

    static func guess(payee: String) -> ExpenseCategory {
        let name = payee.lowercased()
        for (needles, category) in rules {
            for needle in needles where name.contains(needle) { return category }
        }
        return .other
    }

    /// Hotel aggregators sell flights too; when the SMS mentions a flight the
    /// airfare reading wins.
    static func guess(payee: String, message: String) -> ExpenseCategory {
        let guessed = guess(payee: payee)
        let lower = message.lowercased()
        if guessed == .hotel, lower.contains("flight") || lower.contains("airline") {
            return .airfare
        }
        return guessed
    }
}
