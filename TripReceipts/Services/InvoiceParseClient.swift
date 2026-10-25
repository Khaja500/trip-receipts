import Foundation

/// Where the parser's per-install token is kept. The app uses the Keychain;
/// the command-line check keeps it in memory.
protocol TokenStore {
    func read() -> String?
    func save(_ value: String)
    func delete()
}

/// The app's side of the invoice parser service (`invoice-parser/`): one
/// receipt up, the fields it states back. Foundation only, so
/// `Tools/receipt-check.sh` can drive it against a local server.
struct InvoiceParseClient {
    /// The Setup field holding the server address.
    static let serverKey = "parser.server"

    /// What the app knows about the payment. The rule-based reader takes
    /// only the currency — a hint must never make an invoice match. Gemini,
    /// when the server has it, also gets the SMS to judge the two together;
    /// what it reads is still compared field by field on the phone.
    struct Hints: Encodable {
        var amount: Double
        var currency: String
        var date: String
        var payee: String
        var message: String?
    }

    let server: URL
    let tokens: TokenStore
    var timeout: TimeInterval = VerifierRules.parserTimeout

    // MARK: - Calls

    /// Sends the receipt, and the text the phone already read off it, and
    /// returns what the parser found. Registers for a token on first use and
    /// again if the server has forgotten it.
    func parse(_ file: Data, filename: String, text: String?, hints: Hints?) async throws -> ParsedInvoice {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        var token = try await currentToken(session)
        for attempt in 0..<2 {
            let request = try parseRequest(file, filename: filename, text: text, hints: hints, token: token)
            let (data, status) = try await send(request, session)
            switch status {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let invoice = try? decoder.decode(ParsedInvoice.self, from: data) else {
                    throw InvoiceParseError.unreadableAnswer
                }
                return invoice
            case 401 where attempt == 0:
                tokens.delete()
                token = try await register(session)
            default:
                throw InvoiceParseError(status: status, data: data)
            }
        }
        throw InvoiceParseError.rejected(status: 401, message: nil)
    }

    /// For Setup's "Check connection": the server answers and issues a token.
    func check() async throws -> String {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: server.appendingPathComponent("v1/health"))
        request.httpMethod = "GET"
        let (data, status) = try await send(request, session)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else {
            throw InvoiceParseError(status: status, data: data)
        }
        _ = try await currentToken(session)
        return "parser v\(json["version"] as? String ?? "?")"
    }

    private func currentToken(_ session: URLSession) async throws -> String {
        if let token = tokens.read() { return token }
        return try await register(session)
    }

    private func register(_ session: URLSession) async throws -> String {
        var request = URLRequest(url: server.appendingPathComponent("v1/install"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"app":"TripReceipts"}"#.utf8)
        let (data, status) = try await send(request, session)
        guard status == 201,
              let token = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String
        else { throw InvoiceParseError(status: status, data: data) }
        tokens.save(token)
        return token
    }

    // MARK: - Requests

    private func parseRequest(
        _ file: Data, filename: String, text: String?, hints: Hints?, token: String
    ) throws -> URLRequest {
        let boundary = "TripReceipts-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, filename: String? = nil, type: String? = nil, _ data: Data) {
            var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
            if let filename { head += "; filename=\"\(filename.replacingOccurrences(of: "\"", with: ""))\"" }
            if let type { head += "\r\nContent-Type: \(type)" }
            body.append(Data((head + "\r\n\r\n").utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }

        part("file", filename: filename, type: Self.contentType(of: file), file)
        if let text, !text.isEmpty { part("text", type: "text/plain; charset=utf-8", Data(text.utf8)) }
        if let hints { part("hints", type: "application/json", try JSONEncoder().encode(hints)) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: server.appendingPathComponent("v1/parse"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Ephemeral, so a receipt never lands in the URL cache, and bounded as a
    /// whole: past the timeout the phone's own reading is used instead.
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private func send(_ request: URLRequest, _ session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .timedOut {
            throw InvoiceParseError.timedOut
        } catch {
            throw InvoiceParseError.unreachable(reason: error.localizedDescription)
        }
    }

    static func contentType(of data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: Array("%PDF".utf8)) { return "application/pdf" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.count >= 12, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" { return "image/heic" }
        return "application/octet-stream"
    }

    // MARK: - Address

    /// What was typed in Setup as a URL. A bare address gets https — or http
    /// for this Mac, a .local name or a private network address, the only
    /// places a self-hosted parser without a certificate can be.
    static func serverURL(from text: String) -> URL? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        var candidate = typed
        if !candidate.contains("://") {
            let host = String(candidate.split(separator: "/").first ?? "").split(separator: ":").first.map(String.init) ?? ""
            candidate = (isLocal(host) ? "http://" : "https://") + candidate
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }
}

extension InvoiceParseClient.Hints {
    init(_ payment: ReceiptVerifier.PaymentSide) {
        self.init(
            amount: payment.amount,
            currency: payment.currency,
            date: ISO8601DateFormatter.string(from: payment.paidAt, timeZone: .current,
                                              formatOptions: [.withInternetDateTime]),
            payee: payment.merchant,
            message: payment.message.isEmpty ? nil : payment.message
        )
    }
}

enum InvoiceParseError: LocalizedError, Equatable {
    /// With iOS's own words for why — "local network prohibited", "server
    /// with the specified hostname could not be found" — which is what a
    /// self-hosted setup needs to see.
    case unreachable(reason: String)
    case timedOut
    case unreadableAnswer
    case rejected(status: Int, message: String?)

    init(status: Int, data: Data) {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        self = .rejected(status: status, message: json?["error"] as? String)
    }

    var errorDescription: String? {
        switch self {
        case .unreachable(let reason):
            "Couldn't reach the parser server: \(reason)"
        case .timedOut:
            "The parser took longer than \(Int(VerifierRules.parserTimeout)) seconds."
        case .unreadableAnswer:
            "The parser's answer couldn't be read."
        case .rejected(429, _):
            "The parser is busy; try again shortly."
        case .rejected(let status, let message):
            "The parser answered \(status)" + (message.map { ": \($0)" } ?? ".")
        }
    }
}
