import Foundation
import CryptoKit

/// The fingerprint that makes a stored SMS checkable later. Taken at capture
/// over sender + received time + text; if any of those were edited afterwards,
/// recomputing gives a different value and the detail view says so.
enum ProofHasher {
    static func hash(sender: String, receivedAt: Date, text: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: receivedAt)
        let payload = "\(sender)\n\(stamp)\n\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Short form for printing on a report page.
    static func short(_ hash: String) -> String {
        guard hash.count >= 16 else { return hash }
        let head = hash.prefix(8)
        let tail = hash.suffix(8)
        return "\(head)…\(tail)"
    }
}
