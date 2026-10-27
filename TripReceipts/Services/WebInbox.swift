import Foundation
import SwiftData

/// Payments added on the website. The site can't edit `transactions.json` —
/// the phone rewrites it whole on every sync — so it leaves each payment in
/// `web-inbox/` in the same repo: its receipts under `web-inbox/<uid>/`, then
/// `web-inbox/<uid>.json` last, so a JSON file means its receipts are there.
///
/// The phone files each one as a payment, then deletes it from the folder.
/// The sync that follows puts it back on the website with everything else.
struct WebInbox {
    static let folder = "web-inbox"

    struct Entry: Decodable {
        var uid: String
        var amount: Double
        var currency: String
        var merchant: String
        var category: String
        var paidAt: Date
        var instrument: String
        var notes: String
        var status: String
        var receipts: [Receipt]

        struct Receipt: Decodable {
            var path: String
            var filename: String
            var isPDF: Bool
        }
    }

    let token: String
    let owner: String
    let repo: String

    /// Files everything waiting in the folder and returns the new payments.
    /// Safe to repeat: an entry whose payment already exists is only cleared.
    @MainActor
    func pull(into store: PaymentStore) async throws -> [Payment] {
        var created: [Payment] = []
        for item in try await list(Self.folder) where item.type == "file" && item.name.hasSuffix(".json") {
            guard let entry = try await entry(at: item) else { continue }
            if store.payment(uid: entry.uid) == nil {
                created.append(try await file(entry, into: store))
            }
            // Receipts first, the JSON last: if this stops halfway, the JSON
            // still marks the entry, and the next pull finishes clearing it.
            for receipt in try await list("\(Self.folder)/\(entry.uid)") where receipt.type == "file" {
                try await delete(receipt, message: "Filed on iPhone: \(receipt.name)")
            }
            try await delete(item, message: "Filed on iPhone: \(entry.merchant)")
        }
        return created
    }

    /// Nil for a file that isn't a payment. It stays in the folder for a
    /// person to look at rather than blocking the ones after it.
    private func entry(at item: Item) async throws -> Entry? {
        let data = try await raw(item.path)
        guard let entry = try? Self.decoder.decode(Entry.self, from: data),
              entry.uid.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil,
              "\(entry.uid).json" == item.name,
              entry.amount > 0
        else { return nil }
        return entry
    }

    @MainActor
    private func file(_ entry: Entry, into store: PaymentStore) async throws -> Payment {
        // Every receipt is fetched before anything is saved, so a dropped
        // connection leaves no half-filed payment behind.
        var receipts: [(Data, Entry.Receipt)] = []
        for receipt in entry.receipts where receipt.path.hasPrefix("\(Self.folder)/\(entry.uid)/") {
            receipts.append((try await raw(receipt.path), receipt))
        }

        let instrument = entry.instrument.trimmingCharacters(in: .whitespacesAndNewlines)
        let payment = store.addManual(
            amount: entry.amount,
            currency: entry.currency.isEmpty ? "INR" : entry.currency,
            merchant: entry.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            category: ExpenseCategory(rawValue: entry.category) ?? .other,
            paidAt: entry.paidAt,
            instrument: instrument.isEmpty ? "Added on the website" : instrument,
            notes: entry.notes,
            status: PaymentStatus(rawValue: entry.status) ?? .pending,
            uid: entry.uid
        )
        for (data, receipt) in receipts {
            let check = await ReceiptCheck.run(data: data, isPDF: receipt.isPDF,
                                               filename: receipt.filename, for: .init(payment))
            store.attachReceipt(data, isPDF: receipt.isPDF, filename: receipt.filename,
                                check: check, to: payment)
        }
        return payment
    }

    // MARK: - GitHub

    private struct Item: Decodable {
        var name: String
        var path: String
        var sha: String
        var type: String
    }

    /// The website sends whole-second ISO 8601; fractional seconds are
    /// accepted too, in case a browser adds them.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }()

    /// A folder's files; empty when it doesn't exist, which is the usual case.
    private func list(_ path: String) async throws -> [Item] {
        let (data, status) = try await send(try request("GET", path: path))
        switch status {
        case 200: return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        case 404: return []
        default: throw SyncError(status: status, data: data)
        }
    }

    private func raw(_ path: String) async throws -> Data {
        var request = try request("GET", path: path)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, status) = try await send(request)
        guard status == 200 else { throw SyncError(status: status, data: data) }
        return data
    }

    private func delete(_ item: Item, message: String) async throws {
        var request = try request("DELETE", path: item.path)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": message, "sha": item.sha])
        let (data, status) = try await send(request)
        // Already gone is as good as deleted.
        guard status == 200 || status == 404 else { throw SyncError(status: status, data: data) }
    }

    private func request(_ method: String, path: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/contents/\(path)"
        guard let url = components.url else { throw SyncError(status: 0, data: Data()) }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
