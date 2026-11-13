import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Fragment-only secret: the server never receives it or the recipient's private key.
public struct DelegationLink: Codable, Equatable, Identifiable {
    public let server: String
    public let group: String
    public let secret: Data
    public var id: String { server + ":" + group }
    public var url: String { "https://\(server)/i/\(group)#\(GuestCrypto.base64URL(secret))" }
    public init(server: String, group: String, secret: Data) throws {
        guard Self.code(group), secret.count == 32 else { throw GuestCrypto.Failure.invalidEnvelope }
        self.server = try GuestInvite.normalizeServer(server); self.group = group; self.secret = secret
    }
    public static func parse(_ value: String) throws -> Self {
        guard let url = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.user == nil, url.password == nil, url.query == nil,
              let host = url.host, let fragment = url.percentEncodedFragment,
              url.percentEncodedPath == url.path, !fragment.contains("%") else { throw GuestCrypto.Failure.invalidEnvelope }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "i" else { throw GuestCrypto.Failure.invalidEnvelope }
        return try Self(server: host + (url.port.map { ":\($0)" } ?? ""), group: String(parts[2]), secret: GuestCrypto.decodeBase64URL(fragment))
    }
    static func code(_ value: String) -> Bool {
        value.utf8.count == 22 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

public enum DelegationProof {
    private static func keys(signPublic: String, guestPublic: String) throws {
        let signBytes = try GuestCrypto.decodeBase64URL(signPublic)
        guard signBytes.count == 32,
              signPublic == GuestCrypto.base64URL(signBytes) else { throw GuestCrypto.Failure.invalidKey }
        let bytes = try GuestCrypto.decodeBase64URL(guestPublic)
        _ = try P256.KeyAgreement.PublicKey(derRepresentation: bytes)
        guard guestPublic == GuestCrypto.base64URL(bytes) else { throw GuestCrypto.Failure.invalidKey }
    }
    public static func passMAC(secret: Data, group: String, signPublic: String, guestPublic: String) throws -> String {
        guard secret.count == 32, DelegationLink.code(group) else { throw GuestCrypto.Failure.invalidKey }
        try keys(signPublic: signPublic, guestPublic: guestPublic)
        let material = Data("entrixy-pass-v1|\(group)|\(signPublic)|\(guestPublic)".utf8)
        return HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
    }
    public static func checkMAC(_ mac: String, secret: Data, group: String, signPublic: String, guestPublic: String) throws -> Bool {
        guard mac.utf8.count == 64, mac.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        let expected = try passMAC(secret: secret, group: group, signPublic: signPublic, guestPublic: guestPublic)
        return zip(mac.utf8, expected.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func material(server: String, childID: Int, signPublic: String, guestPublic: String) throws -> Data {
        guard childID > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        try keys(signPublic: signPublic, guestPublic: guestPublic)
        return Data("entrixy-vouch-v1|\(try GuestInvite.normalizeServer(server))|\(childID)|\(signPublic)|\(guestPublic)".utf8)
    }
    /// Parent invitation key, rather than device key: the owner independently knows this public key.
    public static func vouch(userKey: String, server: String, childID: Int, signPublic: String, guestPublic: String) throws -> String {
        try GuestCrypto.signingKey(userKey: userKey).signature(for: material(server: server, childID: childID, signPublic: signPublic, guestPublic: guestPublic)).base64EncodedString()
    }
    public static func verifyVouch(_ signature: String, parentPublic: Data, server: String, childID: Int, signPublic: String, guestPublic: String) throws -> Bool {
        guard let bytes = Data(base64Encoded: signature), bytes.count == 64 else { return false }
        return try GuestCrypto.verify(signature: bytes, material: material(server: server, childID: childID, signPublic: signPublic, guestPublic: guestPublic), publicKey: parentPublic)
    }
}
