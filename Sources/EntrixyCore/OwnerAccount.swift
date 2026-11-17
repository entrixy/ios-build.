import Foundation
import CoreFoundation

/// One owner per server. Pending registration is durable: a lost reply is never retried.
public struct OwnerAccount: Codable, Identifiable, Equatable {
    public let server: String
    public let masterKey: Data
    public var credentials: OwnerCredentials?
    public var objects: [OwnerObject]?
    public var issuedKeys: [OwnerIssuedKey]?
    public var delegatedKeys: [OwnerDelegatedKey]?
    public var reservedGuestIDs: [Int]?
    public var androidKeyFailures: [String: String]?
    public var androidKeys: [AndroidOwnerKeyMaterial]?
    public var bleRevocations: [BLERevocation]?
    public var bleArchivedObjects: [OwnerObject]?
    public var bleRestoreObjectIDs: [String: [Int]]?
    public var bleRestorePending: [UUID]?
    public var blePairings: [BLEPairingRecord]?
    public var bleMoves: [OwnerBLEMove]?
    public var hostLabel: String?
    public var lastSynced: Date?
    public var bundleRefreshQueue: [String: String]?
    public var registrationPhase: OwnerRegistrationPhase?
    public var serverSettings: OwnerServerSettings?
    public var ownershipLost: Bool?
    public var id: String { server }
    public var registrationPending: Bool { credentials == nil }

    public init(server: String) throws {
        self.server = try GuestInvite.normalizeServer(server)
        masterKey = GuestCrypto.randomBytes(count: 32)
        registrationPhase = .prepared
    }

    public init(importing server: String, masterKey: Data, credentials: OwnerCredentials?) throws {
        self.server = try GuestInvite.normalizeServer(server); self.masterKey = masterKey; self.credentials = credentials
        try validate()
    }

    public func validate() throws {
        try serverSettings?.validate()
        guard server == (try GuestInvite.normalizeServer(server)), masterKey.count == 32 else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        if let hostLabel { guard hostLabel.count <= 40, !hostLabel.contains("\n"), !hostLabel.contains("\r") else { throw GuestCrypto.Failure.invalidEnvelope } }
        try credentials?.validate()
        let reserved = reservedGuestIDs ?? []
        guard reserved.count <= 65535, Set(reserved).count == reserved.count, reserved.allSatisfy({ (1...65535).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let android = androidKeys ?? []
        guard (androidKeyFailures ?? [:]).count <= 1000,
              (androidKeyFailures ?? [:]).allSatisfy({ Int($0.key).map { $0 > 0 } == true && ["not_found", "delegated_review", "verification_required"].contains($0.value) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        guard android.count <= 1000, Set(android.map(\.serverKeyID)).count == android.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for material in android { try material.validate(masterKey: masterKey) }
        let revocations = bleRevocations ?? []
        guard revocations.count <= 2000, Set(revocations.map(\.id)).count == revocations.count,
              (bleRestorePending ?? []).count <= 500, Set(bleRestorePending ?? []).count == (bleRestorePending ?? []).count else { throw GuestCrypto.Failure.invalidEnvelope }
        for record in revocations { try record.validate() }
        let scopes = bleRestoreObjectIDs ?? [:]
        guard scopes.count <= 500, scopes.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              scopes.values.allSatisfy({ !$0.isEmpty && $0.count <= 1000 && Set($0).count == $0.count && $0.allSatisfy { $0 > 0 } }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let archived = bleArchivedObjects ?? []
        guard archived.count <= 500, Set(archived.map(\.id)).count == archived.count,
              Set(archived.map(\.id)).isDisjoint(with: Set((objects ?? []).map(\.id))) else { throw GuestCrypto.Failure.invalidEnvelope }
        for object in archived {
            guard object.kind == "ble", object.available == false, object.pending == nil, !object.sent else { throw GuestCrypto.Failure.invalidEnvelope }
            try object.validate(masterKey: masterKey)
        }
        let moves = bleMoves ?? []
        guard moves.count <= 1000, Set(moves.map(\.id)).count == moves.count,
              Set(moves.map(\.objectID)).count == moves.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for move in moves {
            try move.validate()
            guard move.destination != server, (objects ?? []).contains(where: { $0.id == move.objectID && $0.kind == "ble" && $0.bleDeviceID == move.deviceID && $0.numberID == move.sourceNumberID }) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        let pairings = blePairings ?? []
        guard pairings.count <= 500, Set(pairings.map(\.id)).count == pairings.count,
              Set(pairings.map(\.deviceID)).count == pairings.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for pairing in pairings { try pairing.validate(masterKey: masterKey) }
        let objects = objects ?? []
        guard Set(objects.map(\.id)).count == objects.count else { throw GuestCrypto.Failure.invalidEnvelope }
        let numberIDs = objects.compactMap(\.numberID)
        guard Set(numberIDs).count == numberIDs.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for object in objects { try object.validate(masterKey: masterKey) }
        let keys = issuedKeys ?? []
        let refreshes = bundleRefreshQueue ?? [:]
        guard refreshes.count <= 1000, Set(refreshes.keys).isSubset(of: Set(keys.map { $0.id.uuidString })),
              refreshes.values.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw GuestCrypto.Failure.invalidEnvelope }
        guard Set(keys.map(\.id)).count == keys.count, Set(keys.map(\.guestID)).count == keys.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for key in keys {
            try key.validate(masterKey: masterKey)
            if key.company != nil {
                guard objects.filter({ key.numberIDs.contains($0.numberID ?? -1) }).allSatisfy({ $0.kind == "call" }),
                      [key.grantedAccess,key.requestedAccess].compactMap({ $0 }).allSatisfy({ $0.values.allSatisfy({ !$0.nativeOnly && $0.depth == 0 && $0.pool == 1 }) }) else { throw GuestCrypto.Failure.invalidEnvelope }
            }
        }
        let delegated = delegatedKeys ?? []
        guard Set(delegated.map(\.id)).count == delegated.count,
              Set(keys.map(\.guestID) + delegated.map(\.guestID)).count == keys.count + delegated.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for key in delegated { try key.validate(masterKey: masterKey) }
    }
}

public struct OwnerCredentials: Codable, Equatable {
    public let deviceID: String
    public let deviceSecret: String

    public init(deviceID: String, deviceSecret: String) throws {
        self.deviceID = deviceID
        self.deviceSecret = deviceSecret
        try validate()
    }

    public func validate() throws {
        func hex(_ text: String, length: Int) -> Bool {
            text.utf8.count == length && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard hex(deviceID, length: 32), hex(deviceSecret, length: 64) else { throw GuestCrypto.Failure.invalidKey }
    }
}

/// Preserve the entire last valid snapshot on invalid/truncated server responses.
public struct OwnerSnapshot {
    public let rows: [[String: Any]]
    public let keyRows: [[String: Any]]
    public let objectCount: Int
    public let guestKeyCount: Int
    public let accountSpecified: Bool
    public let accountEmail: String?

    public static func decode(_ data: Data) throws -> OwnerSnapshot {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let numbers = body["numbers"] as? [[String: Any]],
              let keys = body["keys"] as? [[String: Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
        func positiveID(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let id = value as? Int, id > 0 else { return nil }
            return id
        }
        var ids = Set<Int>()
        for row in numbers {
            guard let id = positiveID(row["id"]), ids.insert(id).inserted,
                  let kind = row["type"] as? String, ["device", "call", "webhook", "ble"].contains(kind) else {
                throw GuestCrypto.Failure.invalidEnvelope
            }
            if let value = row["data_cipher_revision"], !(value is NSNull) {
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      let revision = value as? Int64, revision >= 0 else { throw GuestCrypto.Failure.invalidEnvelope }
            }
        }
        ids.removeAll()
        for row in keys {
            guard let id = positiveID(row["id"]), ids.insert(id).inserted else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        let accountSpecified = body["account"] != nil
        var email: String?
        if let raw = body["account"], !(raw is NSNull) {
            guard let value = raw as? String, value.utf8.count <= 512, !value.contains("\r"), !value.contains("\n") else { throw GuestCrypto.Failure.invalidEnvelope }
            email = value.isEmpty ? nil : value
        }
        return OwnerSnapshot(rows: numbers, keyRows: keys, objectCount: numbers.count, guestKeyCount: keys.count,accountSpecified:accountSpecified,accountEmail:email)
    }
}
