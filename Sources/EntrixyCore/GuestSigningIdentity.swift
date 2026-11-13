import Foundation

/// Signing identity exists before an owner has supplied K_guest. It is not an
/// invitation with an invented decryption key, and cannot decrypt object data.
public struct GuestSigningIdentity: Codable, Equatable, Identifiable {
    public let server: String
    public let userKey: String
    public var id: String { server + ":" + GuestCrypto.hash(Data(userKey.utf8)) }
    public init(server: String, userKey: String) throws {
        self.server = try GuestInvite.normalizeServer(server)
        guard userKey.utf8.count == 32, try GuestCrypto.decodeBase64URL(userKey).count == 24 else { throw GuestCrypto.Failure.invalidKey }
        self.userKey = userKey
    }
    private enum CodingKeys: String, CodingKey { case server, userKey }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(server: value.decode(String.self, forKey: .server), userKey: value.decode(String.self, forKey: .userKey))
    }
    public init(_ invite: GuestInvite) throws { try self.init(server: invite.server, userKey: invite.userKey) }
    public func invitation(bundleKey: Data) throws -> GuestInvite {
        guard bundleKey.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return try GuestInvite.parse("https://\(server)/key#\(userKey)\(GuestCrypto.base64URL(bundleKey))")
    }
}
