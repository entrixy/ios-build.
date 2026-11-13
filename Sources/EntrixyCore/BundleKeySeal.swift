import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Android Crypto.sealKey/openKey: P-256 SPKI/PKCS8, ECDH, HKDF-SHA256, AES-GCM.
/// Only public recipient material and the sealed envelope may leave the device.
public enum BundleKeySeal {
    public struct Recipient: Codable {
        public let privateKey: String
        public let publicKey: String
    }

    public static func validate(_ recipient: Recipient) throws {
        let key = try P256.KeyAgreement.PrivateKey(derRepresentation: GuestCrypto.decodeBase64URL(recipient.privateKey))
        let publicKey = try P256.KeyAgreement.PublicKey(derRepresentation: GuestCrypto.decodeBase64URL(recipient.publicKey))
        guard key.publicKey.rawRepresentation == publicKey.rawRepresentation else { throw GuestCrypto.Failure.invalidKey }
    }

    public static func makeRecipient() -> Recipient {
        let key = P256.KeyAgreement.PrivateKey()
        return Recipient(privateKey: GuestCrypto.base64URL(key.derRepresentation),
                         publicKey: GuestCrypto.base64URL(key.publicKey.derRepresentation))
    }

    public static func seal(_ bundleKey: Data, recipientPublicKey: String) throws -> String {
        guard bundleKey.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        let recipientDER = try GuestCrypto.decodeBase64URL(recipientPublicKey)
        let recipient = try P256.KeyAgreement.PublicKey(derRepresentation: recipientDER)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let wrapped = try GuestCrypto.encrypt(key: wrappingKey(shared, salt: recipientDER), plaintext: bundleKey)
        return "v1:" + GuestCrypto.base64URL(ephemeral.publicKey.derRepresentation) + "." + wrapped.dropFirst(3)
    }

    public static func open(_ envelope: String, recipient: Recipient) throws -> Data {
        guard envelope.hasPrefix("v1:"), envelope.utf8.count <= 2048 else { throw GuestCrypto.Failure.invalidEnvelope }
        let parts = envelope.dropFirst(3).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        let privateKey = try P256.KeyAgreement.PrivateKey(derRepresentation: GuestCrypto.decodeBase64URL(recipient.privateKey))
        let recipientDER = try GuestCrypto.decodeBase64URL(recipient.publicKey)
        let publicKey = try P256.KeyAgreement.PublicKey(derRepresentation: recipientDER)
        guard privateKey.publicKey.rawRepresentation == publicKey.rawRepresentation else { throw GuestCrypto.Failure.invalidKey }
        let ephemeral = try P256.KeyAgreement.PublicKey(derRepresentation: GuestCrypto.decodeBase64URL(String(parts[0])))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = try GuestCrypto.decrypt(key: wrappingKey(shared, salt: recipientDER), envelope: "v1:" + parts[1])
        guard key.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return key
    }

    private static func wrappingKey(_ shared: SharedSecret, salt: Data) -> Data {
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: Data("entrixy-bundle-key".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}
