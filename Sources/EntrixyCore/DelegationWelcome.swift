import Foundation

/// ShareIn's first message is authenticated with the fragment-only group key.
/// It is presentation data, never authority to install or execute an object.
public struct DelegationWelcome: Equatable {
    public let from: String
    public let text: String
    public static func open(_ cipher: String, secret: Data) throws -> Self {
        guard !cipher.isEmpty, cipher.utf8.count <= 16384 else { throw GuestCrypto.Failure.invalidEnvelope }
        let data = try GuestCrypto.decrypt(key: secret, envelope: cipher)
        guard data.count <= 12288, let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["from"] == nil || row["from"] is String, row["text"] == nil || row["text"] is String else { throw GuestCrypto.Failure.invalidEnvelope }
        let from = row["from"] as? String ?? "", text = row["text"] as? String ?? ""
        guard from.utf8.count <= 512, text.utf8.count <= 2048 else { throw GuestCrypto.Failure.invalidEnvelope }
        return Self(from: from, text: text)
    }
}
