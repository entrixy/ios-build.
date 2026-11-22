import Foundation
import Security
import EntrixyCore

struct SavedGuest: Codable, Identifiable {
    let invite: GuestInvite
    var objects: [GuestObject] = []
    var checkedAt: Date?
    var paused = false
    var bleCache: GuestBLECache? = nil
    // Display/navigation hint only; actual delegation is checked against live allowance.
    var incomingDepth: Int? = nil
    var automation: [String: IncomingAutomationConfiguration]? = nil
    var cameras: [String: ObjectCameraConfiguration]? = nil
    var requiresBLEExitOnRestore: Bool? = nil
    var androidAutomation: [String:AndroidIncomingAutomation]? = nil
    var privacyNetworks: [PrivacyNetwork]? = nil
    var welcome: String? = nil
    var hostLabel: String? = nil
    var localKeyLabel: String? = nil
    var senderLabel: String? = nil
    // Grouping/display hints only. Cryptographic membership uses the receipt.
    var keyGroup: String? = nil
    var sequenceNumber: Int? = nil
    var incomingRecipient: BundleKeySeal.Recipient? = nil
    var importedDelegationLink: DelegationLink? = nil
    var id: String { invite.id }
    func validateObjectSettings() throws {
        if let incomingRecipient { try BundleKeySeal.validate(incomingRecipient) }
        if let importedDelegationLink {
            _ = try DelegationLink(server: importedDelegationLink.server, group: importedDelegationLink.group, secret: importedDelegationLink.secret)
            guard importedDelegationLink.id == keyGroup, importedDelegationLink.server == invite.server else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        guard [hostLabel,localKeyLabel,senderLabel].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }),
              sequenceNumber.map({ (1...Int(Int32.max)).contains($0) }) ?? true else { throw GuestCrypto.Failure.invalidEnvelope }
        if let keyGroup {
            let prefix = invite.server + ":"
            guard keyGroup.hasPrefix(prefix), DelegationLink.code(String(keyGroup.dropFirst(prefix.count))) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        guard welcome.map({ $0.utf8.count <= 16384 }) ?? true else { throw GuestCrypto.Failure.invalidEnvelope }
        try PrivacyNetwork.validate(privacyNetworks ?? [])
        try AndroidIncomingAutomation.validate(androidAutomation ?? [:])
        guard (automation ?? [:]).count <= 1000, (cameras ?? [:]).count <= 1000 else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        for (id, rule) in automation ?? [:] {
            guard !id.isEmpty, id.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
            try rule.owner.validate(); try rule.effective.validate()
        }
        for (id, camera) in cameras ?? [:] {
            guard !id.isEmpty, id.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
            try camera.validate()
        }
    }
}

extension SavedGuest {
    init(android source: AndroidGuestMigration, invite: GuestInvite) {
        self.init(invite: invite, requiresBLEExitOnRestore: true, androidAutomation: source.incomingAutomation, privacyNetworks: source.privacyNetworks)
        hostLabel = source.label; localKeyLabel = source.labelOverride; keyGroup = source.groupID
        senderLabel = source.senderLabel; sequenceNumber = source.localID; incomingRecipient = source.recipient
        importedDelegationLink = source.delegationLink
    }
}

struct SavedState: Codable {
    var identity: Data
    var guests: [SavedGuest]
    var journal: [JournalEntry]? = nil
    var actionCode: LocalActionCode? = nil
    var owners: [OwnerAccount]? = nil
    var usedOwnerPresses: [String: Date]? = nil
    var pendingRestore: BackupRestorePlan? = nil
    var delegations: [DelegationRedemption]? = nil
    var passedAccess: [PassedAccess]? = nil
    var receivedDelegations: [ReceivedDelegation]? = nil
    var incomingMessages: [SavedMessage]? = nil
    var outgoingMessages: [OutgoingMessage]? = nil
    var delegatedJournalLedger: DelegatedJournalLedger? = nil
    var appLockEnabled: Bool? = nil
    var appEntryBiometricEnabled: Bool? = nil
    var objectPreferences: ObjectCatalogPreferences? = nil
    var bleAutomationDisarmed: Set<String>? = nil
    var ownerGuestDefaults: OwnerGuestDefaults? = nil
    var companies: [KnownCompany]? = nil
    var androidArchives: [AndroidBackupDocument]? = nil
    var androidPendingGuests: [AndroidGuestMigration]? = nil
    var selectedOwnerServer: String? = nil
    var networkPrivacy: NetworkPrivacyPreferences? = nil
    var pendingLocalReset: Bool? = nil
}

/// One local, device-only Keychain item. Read/decode failures never mean “new installation”.
protocol StateStorage {
    func load() throws -> SavedState?
    func save(_ state: SavedState) throws
}

struct KeychainStore: StateStorage {
    struct Failure: Error { let status: OSStatus }
    private let service: String
    init(service: String = "com.entrixy.ios.local-state") { self.service = service }
    var biometricService: String {
        service == "com.entrixy.ios.local-state" ? "com.entrixy.ios.action-biometry" : service + ".action-biometry"
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "primary"]
    }

    func load() throws -> SavedState? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw Failure(status: result) }
        let state = try JSONDecoder().decode(SavedState.self, from: data)
        guard state.identity.count == 32 else { throw Failure(status: errSecDecode) }
        try validateOwners(state)
        return state
    }

    private func validateOwners(_ state: SavedState) throws {
        try state.networkPrivacy?.validate()
        if let host = state.selectedOwnerServer { guard try GuestInvite.normalizeServer(host) == host else { throw Failure(status:errSecDecode) } }
        guard (state.bleAutomationDisarmed ?? []).count <= 2000,
              (state.bleAutomationDisarmed ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw Failure(status:errSecDecode) }
        try state.ownerGuestDefaults?.validate()
        try KnownCompany.validateDirectory(state.companies ?? [])
        try AndroidBackupDocument.validateArchives(state.androidArchives ?? [])
        let waiting = state.androidPendingGuests ?? []
        guard waiting.count <= 1000, Set(waiting.map(\.id)).count == waiting.count,
              Set(waiting.map(\.id)).isDisjoint(with:Set(state.guests.map(\.id))) else { throw Failure(status:errSecDecode) }
        for key in waiting { try key.validate() }
        try state.objectPreferences?.validate()
        try state.pendingRestore?.validate()
        let received = state.receivedDelegations ?? []
        guard received.count <= 1000, Set(received.map(\.id)).count == received.count else { throw Failure(status: errSecDecode) }
        for guest in state.guests {
            _ = try guest.bleCache?.open(key: guest.invite.bundleKey)
            try guest.validateObjectSettings()
        }
        let guestIDs = Set(state.guests.map(\.id))
        let incoming = state.incomingMessages ?? [], outgoing = state.outgoingMessages ?? []
        guard incoming.count <= 200, outgoing.count <= 100,
              Set(incoming.map(\.id)).count == incoming.count, Set(outgoing.map(\.id)).count == outgoing.count else { throw Failure(status: errSecDecode) }
        for row in incoming { try row.validate(); guard guestIDs.contains(row.guestID) else { throw Failure(status: errSecDecode) } }
        for row in outgoing { try row.validate() }
        for record in received {
            try record.validate()
            guard Set(record.parts.map(\.guestID)).isSubset(of: guestIDs),
                  Set(record.importedGuestIDs ?? []).isSubset(of: guestIDs.union(waiting.map(\.id))) else { throw Failure(status: errSecDecode) }
        }
        let passed = state.passedAccess ?? []
        guard passed.count <= 500, Set(passed.map(\.id)).count == passed.count else { throw Failure(status: errSecDecode) }
        for access in passed { try access.validate() }
        let pending = state.delegations ?? []
        guard pending.count <= 100, Set(pending.map(\.id)).count == pending.count else { throw Failure(status: errSecDecode) }
        for entry in pending { try entry.validate() }
        let owners = state.owners ?? []
        guard Set(owners.map(\.server)).count == owners.count else { throw Failure(status: errSecDecode) }
        for owner in owners {
            try owner.validate()
            for move in owner.bleMoves ?? [] {
                guard owners.contains(where: { $0.server == move.destination && $0.credentials != nil }) else { throw Failure(status: errSecDecode) }
            }
        }
    }

    func save(_ state: SavedState) throws {
        try validateOwners(state)
        let data = try JSONEncoder().encode(state)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var insert = query
        insert.merge(values) { _, new in new }
        let result = SecItemAdd(insert as CFDictionary, nil)
        if result == errSecDuplicateItem {
            let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            guard updated == errSecSuccess else { throw Failure(status: updated) }
        } else if result != errSecSuccess { throw Failure(status: result) }
    }
}
