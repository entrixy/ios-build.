import Foundation

/// A real Android signing identity can be migrated before its owner supplies
/// K_guest. Missing bundle material is retained, never replaced by a random key.
public struct AndroidGuestMigration: Codable, Identifiable {
    public let localID: Int
    public let identity: GuestSigningIdentity
    public let label: String
    public var oldFingerprint: String
    public let bundleKey: Data?
    public let recipient: BundleKeySeal.Recipient?
    public let incomingAutomation: [String:AndroidIncomingAutomation]?
    public let privacyNetworks: [PrivacyNetwork]?
    public let labelOverride: String?
    public let groupID: String?
    public let senderLabel: String?
    public let delegationLink: DelegationLink?
    public var id: String { identity.id }
    public init(document: AndroidBackupDocument, guest: AndroidBackupDocument.Guest) throws {
        guard try document.guests().contains(guest), let seed = try document.sourceSeed(required:true) else { throw GuestCrypto.Failure.invalidEnvelope }
        localID = guest.localID; identity = try GuestSigningIdentity(server:guest.server,userKey:guest.userKey)
        label = guest.label; oldFingerprint = try MigrationFingerprint.android(seed:seed,server:guest.server)
        bundleKey = try document.invitation(for:guest)?.bundleKey
        recipient = try document.recipient(for:guest)
        incomingAutomation = try document.incomingAutomation(localID:guest.localID)
        privacyNetworks = try document.guestPrivacyNetworks(localID:guest.localID)
        if let encoded = try document.string("guest_key_labels") {
            guard encoded.utf8.count <= 262144, let data = encoded.data(using: .utf8),
                  let labels = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw GuestCrypto.Failure.invalidEnvelope }
            labelOverride = labels[String(guest.localID)]
        } else { labelOverride = nil }
        if let group = try document.string("share_grp_" + String(guest.localID)), !group.isEmpty {
            guard DelegationLink.code(group) else { throw GuestCrypto.Failure.invalidEnvelope }
            groupID = guest.server + ":" + group
            senderLabel = try document.string("share_from_" + group)
            if let secret = try document.string("share_wk_" + group), !secret.isEmpty {
                delegationLink = try DelegationLink(server: guest.server, group: group, secret: GuestCrypto.decodeBase64URL(secret))
            } else { delegationLink = nil }
        } else { groupID = nil; senderLabel = nil; delegationLink = nil }
        try validate()
    }
    public func validate() throws {
        _ = try GuestSigningIdentity(server:identity.server,userKey:identity.userKey)
        guard localID > 0, label.utf8.count <= 512, oldFingerprint.utf8.count == 64,
              oldFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              bundleKey == nil || bundleKey?.count == 32 else { throw GuestCrypto.Failure.invalidEnvelope }
        if let recipient { try BundleKeySeal.validate(recipient) }
        try AndroidIncomingAutomation.validate(incomingAutomation ?? [:])
        try PrivacyNetwork.validate(privacyNetworks ?? [])
        guard [labelOverride,senderLabel].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }) else { throw GuestCrypto.Failure.invalidEnvelope }
        if let groupID {
            let prefix = identity.server + ":"
            guard groupID.hasPrefix(prefix), DelegationLink.code(String(groupID.dropFirst(prefix.count))) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        if let delegationLink {
            _ = try DelegationLink(server: delegationLink.server, group: delegationLink.group, secret: delegationLink.secret)
            guard delegationLink.id == groupID else { throw GuestCrypto.Failure.invalidEnvelope }
        }
    }
}

public extension AndroidBackupDocument {
    var archiveID: String { GuestCrypto.hash(original) }
    func guestMigrations() throws -> [AndroidGuestMigration] {
        try guests().map { try AndroidGuestMigration(document:self,guest:$0) }
    }
    static func validateArchives(_ values: [Self]) throws {
        guard values.count <= 10, Set(values.map(\.archiveID)).count == values.count,
              values.reduce(0,{ $0 + $1.original.count }) <= BackupEnvelope.maxPayloadSize else { throw GuestCrypto.Failure.invalidEnvelope }
        for value in values { try value.validate() }
    }
}
