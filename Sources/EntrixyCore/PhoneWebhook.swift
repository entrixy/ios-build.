import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// HostService.postWebhook: the receiver verifies the canonical text, not JSON
/// serialization. The object identifier is the server's, never a local UUID.
public enum PhoneWebhook {
    public static func action(requested: GuestAction?, toggles: Bool, position: String?) -> GuestAction {
        if requested == .close { return .close }
        if requested == .toggle || (requested == nil && toggles) { return ["open", "opening"].contains(position ?? "") ? .close : .open }
        return .open
    }
    public static func request(numberID: Int, action: GuestAction, secret: String,
                               epoch: Int64 = Int64(Date().timeIntervalSince1970),
                               nonce: Data = GuestCrypto.randomBytes(count: 8)) throws -> Data {
        guard numberID > 0, [.open, .close].contains(action), !secret.isEmpty, secret.utf8.count <= 1024,
              epoch > 0, nonce.count == 8 else { throw GuestCrypto.Failure.invalidEnvelope }
        let hex = nonce.map { String(format: "%02x", $0) }.joined()
        let material = Data("\(epoch).\(hex).\(action.rawValue).\(numberID)".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: ["object_id": numberID, "action": action.rawValue,
            "timestamp": epoch, "nonce": hex, "signature": signature], options: .sortedKeys)
    }
    public static func reply(status: Int, data: Data) throws -> PhoneWebhookReply {
        guard (100...599).contains(status), data.count <= 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let raw = json["level"] as? String ?? ""
        let level = ["success", "warning", "danger", "info"].contains(raw) ? raw :
            (json["status"] as? String == "ok" ? "success" : json["status"] as? String == "error" ? "danger" : (200...299).contains(status) ? "success" : "danger")
        let text = json["message"] as? String
        let position = json["position"] as? String
        return PhoneWebhookReply(level: level, message: text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String($0.prefix(120)) },
            position: position.flatMap { ["open", "closed", "unknown"].contains($0) ? $0 : nil },
            closeIn: max(0, min(3600, json["close_in"] as? Int ?? 0)))
    }
}

public struct PhoneWebhookReply: Equatable {
    public let level: String
    public let message: String?
    public let position: String?
    public let closeIn: Int
    public func positionAfter(action: GuestAction, toggles: Bool) -> String? {
        position ?? (level != "danger" && (action == .close || toggles) ? (action == .close ? "closed" : "open") : nil)
    }
    public func forgetting(position: String) -> (after: TimeInterval, position: String) {
        position == "open" && closeIn > 0 ? (TimeInterval(closeIn), "closed") : (2, "unknown")
    }
}
