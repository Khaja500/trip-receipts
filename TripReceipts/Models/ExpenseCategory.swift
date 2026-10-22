import Foundation

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable {
    case airfare, rail, cab, localTransport, hotel, meals, fuel, tollsParking, visaForex, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airfare: "Airfare"
        case .rail: "Rail"
        case .cab: "Cab / Taxi"
        case .localTransport: "Local transport"
        case .hotel: "Hotel"
        case .meals: "Meals"
        case .fuel: "Fuel"
        case .tollsParking: "Tolls / Parking"
        case .visaForex: "Visa / Forex"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .airfare: "airplane"
        case .rail: "tram.fill"
        case .cab: "car.fill"
        case .localTransport: "bus.fill"
        case .hotel: "bed.double.fill"
        case .meals: "fork.knife"
        case .fuel: "fuelpump.fill"
        case .tollsParking: "parkingsign.circle.fill"
        case .visaForex: "doc.text.fill"
        case .other: "square.grid.2x2"
        }
    }

    /// Categories that suggest, on their own, that a payment was work travel.
    var isTravel: Bool {
        switch self {
        case .airfare, .rail, .cab, .localTransport, .hotel, .tollsParking, .visaForex: true
        case .meals, .fuel, .other: false
        }
    }
}
