import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wire compatibility with the full Entrixy Android client's v1 suite.
/// Key material and invitation strings never belong in HTTP request bodies.
public enum GuestCrypto {
    public enum Failure: Error { case invalidEnvelope, invalidKey }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func signingKey(userKey: String, deviceFingerprint: String? = nil) throws -> Curve25519.Signing.PrivateKey {
        let info = deviceFingerprint == nil ? "entrixy-guest-sign-v1" : "entrixy-guest-device-v1"
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(userKey.utf8)),
            salt: Data((deviceFingerprint ?? "").utf8), info: Data(info.utf8),
            outputByteCount: 32)
        return try seed.withUnsafeBytes { try Curve25519.Signing.PrivateKey(rawRepresentation: Data($0)) }
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ text: String) throws -> Data {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), text.count % 4 != 1 else {
            throw Failure.invalidEnvelope
        }
        let normal = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let result = Data(base64Encoded: normal + String(repeating: "=", count: (4 - normal.count % 4) % 4)) else {
            throw Failure.invalidEnvelope
        }
        return result
    }

    /// Sign the exact bytes that the transport will send, without JSON reserialization.
    public static func headers(userKey: String, endpoint: String, body: Data,
                               deviceFingerprint: String? = nil,
                               timestamp: Int64 = Int64(Date().timeIntervalSince1970),
                               nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) throws -> [String: String] {
        let keyID = hash(Data(userKey.utf8))
        let material = "v1.\(keyID).\(timestamp).\(nonce).\(endpoint).\(hash(body))"
        let signature = try signingKey(userKey: userKey, deviceFingerprint: deviceFingerprint)
            .signature(for: Data(material.utf8))
        return ["X-Entrixy-Key": keyID, "X-Entrixy-Ts": String(timestamp),
                "X-Entrixy-Nonce": nonce, "X-Entrixy-Suite": "v1",
                "X-Entrixy-Sig": signature.base64EncodedString()]
    }

    public static func verify(signature: Data, material: Data, publicKey: Data) throws -> Bool {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return key.isValidSignature(signature, for: material)
    }

    public static func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    public static func devicePublicKey(userKey: String, fingerprint: String) throws -> String {
        base64URL(try signingKey(userKey: userKey, deviceFingerprint: fingerprint).publicKey.rawRepresentation)
    }

    public static func hello(userKey: String, fingerprint: String,
                             timestamp: Int64 = Int64(Date().timeIntervalSince1970),
                             nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) throws -> [String: String] {
        let id = hash(Data(userKey.utf8))
        let message = "v1.\(id).\(timestamp).\(nonce).guest_hello.\(hash(Data(fingerprint.utf8)))"
        let sig = try signingKey(userKey: userKey, deviceFingerprint: fingerprint).signature(for: Data(message.utf8))
        return ["type": "guest_hello", "client": "app", "key_id": id,
                "device_fp": fingerprint, "ts": String(timestamp), "nonce": nonce,
                "suite": "v1", "sig": sig.base64EncodedString()]
    }

    public static func encrypt(key: Data, plaintext: Data) throws -> String {
        guard key.count == 32 else { throw Failure.invalidKey }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = sealed.combined else { throw Failure.invalidEnvelope }
        return "v1:" + base64URL(combined)
    }

    public static func decrypt(key: Data, envelope: String) throws -> Data {
        guard key.count == 32 else { throw Failure.invalidKey }
        guard envelope.hasPrefix("v1:") else { throw Failure.invalidEnvelope }
        let combined = try decodeBase64URL(String(envelope.dropFirst(3)))
        guard combined.count >= 28 else { throw Failure.invalidEnvelope }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key))
    }
}
