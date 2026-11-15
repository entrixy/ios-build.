import Foundation
import Security
import EntrixyCore

struct SavedGuest: Codable, Identifiable {
    let invite: GuestInvite
    var objects: [GuestObject] = []
    var checkedAt: Date?
    var paused = false
    var bleCache: GuestBLECache? = nil
    var id: String { invite.id }
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
        try state.pendingRestore?.validate()
        let received = state.receivedDelegations ?? []
        guard received.count <= 1000, Set(received.map(\.id)).count == received.count else { throw Failure(status: errSecDecode) }
        for guest in state.guests { _ = try guest.bleCache?.open(key: guest.invite.bundleKey) }
        let guestIDs = Set(state.guests.map(\.id))
        let incoming = state.incomingMessages ?? [], outgoing = state.outgoingMessages ?? []
        guard incoming.count <= 200, outgoing.count <= 100,
              Set(incoming.map(\.id)).count == incoming.count, Set(outgoing.map(\.id)).count == outgoing.count else { throw Failure(status: errSecDecode) }
        for row in incoming { try row.validate(); guard guestIDs.contains(row.guestID) else { throw Failure(status: errSecDecode) } }
        for row in outgoing { try row.validate() }
        for record in received {
            try record.validate()
            guard Set(record.parts.map(\.guestID)).isSubset(of: guestIDs) else { throw Failure(status: errSecDecode) }
        }
        let passed = state.passedAccess ?? []
        guard passed.count <= 500, Set(passed.map(\.id)).count == passed.count else { throw Failure(status: errSecDecode) }
        for access in passed { try access.validate() }
        let pending = state.delegations ?? []
        guard pending.count <= 100, Set(pending.map(\.id)).count == pending.count else { throw Failure(status: errSecDecode) }
        for entry in pending { try entry.validate() }
        let owners = state.owners ?? []
        guard Set(owners.map(\.server)).count == owners.count else { throw Failure(status: errSecDecode) }
        for owner in owners { try owner.validate() }
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
