import Foundation

/// Android message_send / key_delegate?a=message envelopes. Text is never a command.
public enum GuestMessageCrypto {
    public static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500,
              text.utf8.count <= 2048 else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public static func seal(_ text: String, bundleKey: Data) throws -> String {
        try validateText(text)
        return try GuestCrypto.encrypt(key: bundleKey, plaintext: Data(text.utf8))
    }
    public static func seal(_ text: String, recipientPublic: String) throws -> String {
        try validateText(text)
        let key = GuestCrypto.randomBytes(count: 32)
        let sealed = try BundleKeySeal.seal(key, recipientPublicKey: recipientPublic)
        let cipher = sealed + "|" + (try GuestCrypto.encrypt(key: key, plaintext: Data(text.utf8)))
        guard cipher.utf8.count <= 4096 else { throw GuestCrypto.Failure.invalidEnvelope }
        return cipher
    }
    public static func open(_ cipher: String, bundleKey: Data, recipient: BundleKeySeal.Recipient? = nil) throws -> String {
        guard !cipher.isEmpty, cipher.utf8.count <= 4096 else { throw GuestCrypto.Failure.invalidEnvelope }
        let plain: Data
        if cipher.contains("|") {
            let parts = cipher.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, let recipient else { throw GuestCrypto.Failure.invalidKey }
            let key = try BundleKeySeal.open(String(parts[0]), recipient: recipient)
            plain = try GuestCrypto.decrypt(key: key, envelope: String(parts[1]))
        } else { plain = try GuestCrypto.decrypt(key: bundleKey, envelope: cipher) }
        guard let text = String(data: plain, encoding: .utf8) else { throw GuestCrypto.Failure.invalidEnvelope }
        try validateText(text)
        return text
    }
    public static func acknowledgementHash(_ cipher: String) -> String { String(GuestCrypto.hash(Data(cipher.utf8)).prefix(24)) }
}
public enum MessageAcknowledgement: String { case delivered, read }
public protocol GuestMessageTransport {
    func acknowledgeMessage(invite: GuestInvite, fingerprint: String, kind: MessageAcknowledgement, hash: String) async throws
}
