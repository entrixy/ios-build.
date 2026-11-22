import Foundation

public enum DelegationOperation: String, Codable { case create, list, edit, revoke, cancel, vouch, message }
public protocol DelegationTransport {
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data
    func delegationInfo(server: String, group: String) async throws -> Data
    func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data
    func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite?
}

/// Must be persisted before redeem. Unknown delivery never generates replacement keys.
public struct DelegationRedemption: Codable, Identifiable {
    public struct Part: Codable {
        public let code: String
        public let userKey: String
    }
    public let link: DelegationLink
    public let recipient: BundleKeySeal.Recipient
    public let parts: [Part]
    public var completedCodes: [String] = []
    public var sent: Bool = false
    public var welcomeCipher: String? = nil
    public var importedGuestIDs: [String]? = nil
    public var importedBaselineCodes: [String]? = nil
    public var id: String { link.id }

    public static func availableCodes(info: Data, group: String) throws -> [String] {
        guard let json = try JSONSerialization.jsonObject(with: info) as? [String: Any],
              json["grp"] as? String == group, let overall = json["state"] as? String, ["new", "cancelled"].contains(overall),
              let rows = json["parts"] as? [[String: Any]], !rows.isEmpty, rows.count <= 16 else { throw GuestCrypto.Failure.invalidEnvelope }
        var codes: [String] = [], seen = Set<String>()
        for row in rows {
            guard let code = row["code"] as? String, DelegationLink.code(code), seen.insert(code).inserted,
                  let state = row["state"] as? String, ["new", "redeemed", "expired", "cancelled"].contains(state) else { throw GuestCrypto.Failure.invalidEnvelope }
            if overall == "new" && (state == "new" || state == "redeemed") { codes.append(code) }
        }
        return codes
    }
    /// Android's migrated record has no part-code mapping. Already redeemed
    /// rows belong to the previous installation and must never get new keys.
    public static func redeemedCodes(info: Data, group: String) throws -> [String] {
        _ = try availableCodes(info: info, group: group)
        guard let json = try JSONSerialization.jsonObject(with: info) as? [String: Any],
              let rows = json["parts"] as? [[String: Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
        return rows.compactMap { $0["state"] as? String == "redeemed" ? $0["code"] as? String : nil }
    }
    public init(link: DelegationLink, info: Data, recipient: BundleKeySeal.Recipient? = nil, excludingCodes: Set<String> = [], importedGuestIDs: [String] = [], importedBaselineCodes: [String] = []) throws {
        let codes = try Self.availableCodes(info: info, group: link.group).filter { !excludingCodes.contains($0) }
        guard !codes.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        self.link = link; self.recipient = recipient ?? BundleKeySeal.makeRecipient()
        self.importedGuestIDs = importedGuestIDs.isEmpty ? nil : importedGuestIDs
        self.importedBaselineCodes = importedGuestIDs.isEmpty ? nil : importedBaselineCodes
        parts = codes.map { Part(code: $0, userKey: GuestCrypto.base64URL(GuestCrypto.randomBytes(count: 24))) }
        if let json = try JSONSerialization.jsonObject(with: info) as? [String: Any],
           let cipher = json["welcome_cipher"] as? String,
           (try? DelegationWelcome.open(cipher, secret: link.secret)) != nil { welcomeCipher = cipher }
    }
    public func validate() throws {
        let imported = importedGuestIDs ?? [], baseline = importedBaselineCodes ?? []
        guard parts.count + imported.count <= 16, Set(imported).count == imported.count,
              baseline.count <= 16, Set(baseline).count == baseline.count, baseline.allSatisfy(DelegationLink.code) else { throw GuestCrypto.Failure.invalidEnvelope }
        for id in imported {
            guard id.hasPrefix(link.server + ":"), id.utf8.count == link.server.utf8.count + 65,
                  id.utf8.suffix(64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        if let welcomeCipher { _ = try DelegationWelcome.open(welcomeCipher, secret: link.secret) }
        _ = try DelegationLink(server: link.server, group: link.group, secret: link.secret)
        try BundleKeySeal.validate(recipient)
        guard (1...16).contains(parts.count), Set(parts.map(\.code)).count == parts.count,
              Set(completedCodes).count == completedCodes.count,
              Set(completedCodes).isSubset(of: Set(parts.map(\.code))), completedCodes.isEmpty || sent else { throw GuestCrypto.Failure.invalidEnvelope }
        for part in parts {
            guard DelegationLink.code(part.code), part.userKey.utf8.count == 32,
                  try GuestCrypto.decodeBase64URL(part.userKey).count == 24 else { throw GuestCrypto.Failure.invalidKey }
        }
    }
    public func request(fingerprint: String) throws -> Data {
        guard fingerprint.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...16).contains(parts.count), Set(parts.map(\.code)).count == parts.count else { throw GuestCrypto.Failure.invalidEnvelope }
        try validate()
        let rows = try parts.map { part -> [String: Any] in
            guard DelegationLink.code(part.code), part.userKey.utf8.count == 32 else { throw GuestCrypto.Failure.invalidKey }
            let pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: part.userKey).publicKey.rawRepresentation)
            return ["code": part.code, "key_hash": GuestCrypto.hash(Data(part.userKey.utf8)), "sign_pub": pub,
                    "mac": try DelegationProof.passMAC(secret: link.secret, group: link.group, signPublic: pub, guestPublic: recipient.publicKey)]
        }
        return try JSONSerialization.data(withJSONObject: ["grp": link.group, "guest_pub": recipient.publicKey,
            "suite": "v1", "parts": rows, "device_fp": fingerprint], options: .sortedKeys)
    }
    /// The key returned by the owner is sealed to THIS recipient. A substitute key fails authentication.
    public func invitation(part: Part, keyCipher: String) throws -> GuestInvite {
        guard parts.contains(where: { $0.code == part.code && $0.userKey == part.userKey }) else { throw GuestCrypto.Failure.invalidKey }
        let bundleKey = try BundleKeySeal.open(keyCipher, recipient: recipient)
        return try GuestInvite.parse("https://\(link.server)/key#\(part.userKey)\(GuestCrypto.base64URL(bundleKey))")
    }
}

/// Link handling prepares a form only; acceptance/binding always needs an explicit action.
public enum AccessLink {
    public static func incomingText(_ value: String) throws -> String {
        if let link = try? DelegationLink.parse(value) { return link.url }
        return try GuestInvite.incomingText(value)
    }
}
