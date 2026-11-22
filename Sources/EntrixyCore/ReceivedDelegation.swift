import Foundation

/// Retains the recipient encryption pair for later parts/messages, without keeping
/// a second copy of the signing secrets of installed or locally deleted keys.
public struct ReceivedDelegation: Codable, Identifiable {
    public struct Part: Codable, Equatable {
        public let code: String
        public let guestID: String
    }
    public let link: DelegationLink
    public let recipient: BundleKeySeal.Recipient
    public var parts: [Part]
    public var welcomeCipher: String? = nil
    public var importedGuestIDs: [String]? = nil
    public var importedBaselineCodes: [String]? = nil
    public var welcomeQueued: Bool? = nil
    public var id: String { link.id }
    public var guestIDs: Set<String> { Set(parts.map(\.guestID) + (importedGuestIDs ?? [])) }
    public init(pending: DelegationRedemption) throws {
        try pending.validate()
        link = pending.link; recipient = pending.recipient
        welcomeCipher = pending.welcomeCipher
        importedGuestIDs = pending.importedGuestIDs
        importedBaselineCodes = pending.importedBaselineCodes
        if !(pending.importedGuestIDs ?? []).isEmpty { welcomeQueued = true }
        parts = pending.parts.filter { pending.completedCodes.contains($0.code) }.map {
            Part(code: $0.code, guestID: pending.link.server + ":" + GuestCrypto.hash(Data($0.userKey.utf8)))
        }
        try validate()
    }
    public init(importing link: DelegationLink, recipient: BundleKeySeal.Recipient, guestIDs: [String]) throws {
        self.link = link; self.recipient = recipient; parts = []; importedGuestIDs = guestIDs; welcomeQueued = true
        try validate()
    }
    public func validate() throws {
        if let welcomeCipher { _ = try DelegationWelcome.open(welcomeCipher, secret: link.secret) }
        _ = try DelegationLink(server: link.server, group: link.group, secret: link.secret)
        try BundleKeySeal.validate(recipient)
        let imported = importedGuestIDs ?? [], baseline = importedBaselineCodes ?? []
        guard (1...16).contains(parts.count + imported.count), Set(parts.map(\.code)).count == parts.count,
              Set(parts.map(\.guestID) + imported).count == parts.count + imported.count,
              baseline.count <= 16, Set(baseline).count == baseline.count,
              baseline.allSatisfy(DelegationLink.code) else { throw GuestCrypto.Failure.invalidEnvelope }
        for id in imported {
            guard id.hasPrefix(link.server + ":"), id.utf8.count == link.server.utf8.count + 65,
                  id.utf8.suffix(64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        for part in parts {
            guard DelegationLink.code(part.code), part.guestID.hasPrefix(link.server + ":"),
                  part.guestID.utf8.count == link.server.utf8.count + 65,
                  part.guestID.utf8.suffix(64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
    }
    public mutating func merge(_ other: Self) throws {
        try other.validate()
        guard link == other.link, recipient.privateKey == other.recipient.privateKey,
              recipient.publicKey == other.recipient.publicKey else { throw GuestCrypto.Failure.invalidKey }
        for part in other.parts {
            if let current = parts.first(where: { $0.code == part.code }) { guard current == part else { throw GuestCrypto.Failure.invalidKey } }
            else { parts.append(part) }
        }
        if let cipher = other.welcomeCipher { welcomeCipher = cipher }
        let known = Set(parts.map(\.guestID))
        importedGuestIDs = Array(Set((importedGuestIDs ?? []) + (other.importedGuestIDs ?? [])).subtracting(known)).sorted()
        if let codes = other.importedBaselineCodes {
            importedBaselineCodes = Array(Set((importedBaselineCodes ?? []) + codes).subtracting(Set(parts.map(\.code)))).sorted()
        }
        if other.welcomeQueued == true { welcomeQueued = true }
        try validate()
    }
}
