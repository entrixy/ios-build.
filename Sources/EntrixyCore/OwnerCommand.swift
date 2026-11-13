import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct OwnerCommand {
    public let numberID: Int
    public let action: GuestAction
    public let started: TimeInterval
    private let secret: Data?
    private let kind: String
    private var consumed = false

    public init(numberID: Int, kind: String, action: GuestAction, secret: Data?, now: TimeInterval) throws {
        guard numberID > 0, ["device", "webhook"].contains(kind), action != .toggle,
              kind != "device" || secret?.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        self.numberID = numberID; self.action = action; self.secret = secret; self.kind = kind; started = now
    }
    public func request() throws -> Data {
        guard ["device", "webhook"].contains(kind) else { throw GuestCrypto.Failure.invalidEnvelope }
        return try JSONSerialization.data(withJSONObject: ["type": kind == "device" ? "host_self_call" : "host_self_webhook",
            "number_id": numberID, "action": action.rawValue], options: .sortedKeys)
    }
    public mutating func fire(challenge: [String: Any], now: TimeInterval) throws -> Data {
        guard !consumed, now >= started, now - started < 30, let secret,
              challenge["number_id"] as? Int == numberID,
              let commandID = challenge["command_id"] as? String, !commandID.isEmpty, commandID.utf8.count <= 256,
              let encoded = challenge["nonce"] as? String, let nonce = Data(base64Encoded: encoded), nonce.count == 16 else { throw GuestCrypto.Failure.invalidEnvelope }
        let material = nonce + (action == .close ? Data("close".utf8) : Data())
        let proof = Data(HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: secret)).prefix(16))
        consumed = true // Before the write; an ambiguous write must never be repeated.
        var frame: [String: Any] = ["type": "sock_fire", "number_id": numberID, "command_id": commandID,
            "token": "", "owner_sig": "", "guest_id": 0, "nonce": encoded, "proof": proof.base64EncodedString()]
        if action == .close { frame["action"] = "close" }
        return try JSONSerialization.data(withJSONObject: frame, options: .sortedKeys)
    }
}

public enum OwnerGuestPress {
    /// Signature verification is independent of the relay's guest label or call identifier.
    public static func verify(_ press: [String: Any], userKey: String, server: String, numberID: Int,
                              now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> String {
        try verify(press, publicKey: GuestCrypto.signingKey(userKey: userKey).publicKey.rawRepresentation,
                   server: server, numberID: numberID, now: now)
    }
    public static func verify(_ press: [String: Any], publicKey: Data, server: String, numberID: Int,
                              now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> String {
        guard numberID > 0, let ts = press["ts"] as? Int64, ts > 0, abs(Double(now) - Double(ts)) <= 180,
              let nonce = press["nonce"] as? String, nonce.count == 32,
              nonce.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let action = press["action"] as? String, ["", "open", "close", "toggle"].contains(action),
              let encoded = press["sig"] as? String, let signature = Data(base64Encoded: encoded), signature.count == 64 else { throw GuestCrypto.Failure.invalidEnvelope }
        let host = try GuestInvite.normalizeServer(server)
        let material = Data("press-v1.\(host).\(numberID).\(action).\(ts).\(nonce)".utf8)
        guard try GuestCrypto.verify(signature: signature, material: material, publicKey: publicKey) else { throw GuestCrypto.Failure.invalidKey }
        return nonce.lowercased()
    }
}
