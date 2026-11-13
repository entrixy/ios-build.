import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The action is fixed at the user's tap. A challenge never chooses the direction.
public enum GuestAction: String { case open, close, toggle }

public struct SocketCredential {
    public let guestID: Int
    public let token: Data
    public let ownerSignature: Data
    private let key: Data

    public init(json: [String: Any]) throws {
        guard let id = json["guest_id"] as? Int, (1...65535).contains(id),
              let t = json["token"] as? String, let token = Data(base64Encoded: t), token.count == 3,
              let s = json["sig"] as? String, let signature = Data(base64Encoded: s), signature.count == 16,
              let k = json["gkey"] as? String, let key = Data(base64Encoded: k), key.count == 32,
              Int(token[0]) | Int(token[1]) << 8 == id, token[2] == 1 else {
            throw GuestCrypto.Failure.invalidKey
        }
        guestID = id; self.token = token; ownerSignature = signature; self.key = key
    }

    func proof(nonce: Data, action: GuestAction) throws -> Data {
        // Socket nonce is 16 bytes; BLE uses a different contract.
        guard nonce.count == 16, action != .toggle else { throw GuestCrypto.Failure.invalidEnvelope }
        let material = nonce + (action == .close ? Data("close".utf8) : Data())
        return Data(HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: key)).prefix(16))
    }
}

public enum GuestPress {
    public static func frame(userKey: String, host: String, numberID: Int, wireAction: String,
                             timestamp: Int64 = Int64(Date().timeIntervalSince1970),
                             nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) throws -> Data {
        guard numberID > 0, ["", "open", "close", "toggle"].contains(wireAction),
              nonce.count == 32, nonce.allSatisfy({ $0.isHexDigit && $0.isASCII }), timestamp > 0 else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        let material = Data("press-v1.\(host).\(numberID).\(wireAction).\(timestamp).\(nonce)".utf8)
        // The owner validates the invitation key, NOT the device-bound hello key.
        let signature = try GuestCrypto.signingKey(userKey: userKey).signature(for: material)
        var body: [String: Any] = ["type": "call", "number_id": numberID,
            "press": ["ts": timestamp, "nonce": nonce, "action": wireAction, "sig": signature.base64EncodedString()]]
        if !wireAction.isEmpty { body["action"] = wireAction }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// One outstanding call per connection: legacy call_status may omit number_id.
/// Timeouts make the connection unusable for new calls until it is replaced.
/// The caller must discard this value whenever authorization or transport changes.
public struct GuestActionSession {
    public enum Failure: Error { case busy, expired, unsolicited, malformed }
    public private(set) var numberID: Int?
    private var action: GuestAction = .open
    private var credential: SocketCredential?
    private var started: TimeInterval = 0
    private var consumed = false
    private var usedCommands: Set<String> = []
    private var usedNonces: Set<Data> = []

    public init() {}
    public mutating func begin(numberID: Int, action: GuestAction, credential: SocketCredential?, now: TimeInterval) throws {
        guard self.numberID == nil else { throw Failure.busy }
        guard numberID > 0 else { throw Failure.malformed }
        self.numberID = numberID; self.action = action; self.credential = credential; started = now; consumed = false
    }
    public mutating func fire(challenge: [String: Any], now: TimeInterval) throws -> Data {
        guard let id = numberID, challenge["number_id"] as? Int == id, !consumed,
              let credential else { throw Failure.unsolicited }
        guard now >= started, now - started < 30 else { throw Failure.expired }
        guard let command = challenge["command_id"] as? String, !command.isEmpty, command.utf8.count <= 256,
              let encoded = challenge["nonce"] as? String, let nonce = Data(base64Encoded: encoded), nonce.count == 16,
              !usedCommands.contains(command), !usedNonces.contains(nonce) else { throw Failure.malformed }
        let proof = try credential.proof(nonce: nonce, action: action)
        // Consume BEFORE sending. An uncertain socket write must never be retried.
        consumed = true; usedCommands.insert(command); usedNonces.insert(nonce)
        var frame: [String: Any] = ["type": "sock_fire", "number_id": id, "command_id": command,
            "guest_id": credential.guestID, "token": credential.token.base64EncodedString(),
            "owner_sig": credential.ownerSignature.base64EncodedString(), "nonce": encoded,
            "proof": proof.base64EncodedString()]
        if action == .close { frame["action"] = "close" }
        return try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
    }
    // Deliberately no reset/retry API. Replace the transport before another call.
}
