import Foundation
import CoreFoundation

/// Signed owner decision. Guests may carry this opaque record, but only the
/// controller (or the owner) can authenticate it. GATT ACK is not application.
public struct BLERevocation: Codable, Identifiable, Equatable {
    public let deviceID: UInt32
    public let guestID: UInt16
    public let version: UInt32
    public let revoked: Bool
    public let signature: Data
    public private(set) var controllerResult: UInt8?
    public var id: String { "\(deviceID):\(guestID)" }
    public var applied: Bool { controllerResult == 0x40 }
    public init(deviceID: UInt32, guestID: UInt16, version: UInt32, revoked: Bool, ownerSecret: Data) throws {
        let frame = try BLECrypto.revoke(ownerSecret: ownerSecret, guestID: guestID, version: version, revoked: revoked)
        self.deviceID = deviceID; self.guestID = guestID; self.version = version; self.revoked = revoked
        signature = Data(frame.suffix(16))
        try validate()
    }
    public init(row: [String: Any]) throws {
        func integer(_ key: String) throws -> Int64 {
            guard let n = row[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  let v = Int64(n.stringValue), n == NSNumber(value: v) else { throw GuestCrypto.Failure.invalidEnvelope }
            return v
        }
        let did = try integer("lock_did"), gid = try integer("guest_id"), ver = try integer("version")
        guard (-2_147_483_648...4_294_967_295).contains(did), (1...65535).contains(gid), (1...4_294_967_295).contains(ver),
              let encoded = row["sig"] as? String, let sig = Data(base64Encoded: encoded), sig.count == 16 else { throw GuestCrypto.Failure.invalidEnvelope }
        let revoke = try integer("revoked")
        guard revoke == 0 || revoke == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
        deviceID = did < 0 ? UInt32(bitPattern: Int32(did)) : UInt32(did)
        guestID = UInt16(gid); version = UInt32(ver); revoked = revoke == 1; signature = sig
        try validate()
    }
    public func validate() throws {
        guard deviceID != 0, guestID != 0, version > 0, signature.count == 16,
              controllerResult == nil || controllerResult == 0x40 || controllerResult == 0x41 else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public func verify(ownerSecret: Data) throws -> Bool {
        let expected = try BLECrypto.revoke(ownerSecret: ownerSecret, guestID: guestID, version: version, revoked: revoked)
        guard expected.count == frame.count else { return false }
        return zip(expected, frame).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public var frame: Data {
        BLECrypto.littleEndian(UInt64(guestID), count: 2) + BLECrypto.littleEndian(UInt64(version), count: 4) + Data([revoked ? 1 : 0]) + signature
    }
    public var json: [String: Any] {
        // Match Android's signed Int32 DID representation on the relay wire.
        ["type": "ble_revoke", "lock_did": Int64(Int32(bitPattern: deviceID)), "guest_id": Int(guestID),
         "version": UInt64(version), "revoked": revoked ? 1 : 0, "sig": signature.base64EncodedString()]
    }
    public mutating func receiveControllerResult(_ result: UInt8) throws {
        guard result == 0x40 || result == 0x41 else { throw GuestCrypto.Failure.invalidEnvelope }
        // 0x41 says equal OR newer already exists. Never call that proof that
        // this particular revoked/allowed state was applied.
        controllerResult = result
    }
    public static func merge(_ incoming: [BLERevocation], into existing: [BLERevocation], limit: Int) throws -> [BLERevocation] {
        var result = existing
        guard Set(existing.map(\.id)).count == existing.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for row in existing { try row.validate() }
        for row in incoming {
            try row.validate()
            if let index = result.firstIndex(where: { $0.id == row.id }) {
                let current = result[index]
                if current.version < row.version { result[index] = row }
                else if current.version == row.version {
                    guard current.signature == row.signature, current.revoked == row.revoked else { throw GuestCrypto.Failure.invalidEnvelope }
                }
            } else { result.append(row) }
        }
        guard result.count <= limit else { throw GuestCrypto.Failure.invalidEnvelope }
        return result
    }
    public static func decode(_ data: Data) throws -> [BLERevocation] {
        guard data.count <= 131072, let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = message["items"] as? [[String: Any]], rows.count <= 500 else { throw GuestCrypto.Failure.invalidEnvelope }
        let records = try rows.map { try BLERevocation(row: $0) }
        guard Set(records.map(\.id)).count == records.count else { throw GuestCrypto.Failure.invalidEnvelope }
        return records
    }
}

public extension OwnerAccount {
    /// Queue a key subtree's restrictions before the server mutation. A restore
    /// is called only after a fresh snapshot confirms active owner authority.
    mutating func queueBLEDecision(keyID: UUID, revoked: Bool, epoch: UInt64 = UInt64(Date().timeIntervalSince1970), restrictingObjectIDs: Set<Int>? = nil, forceVersion: Bool = false) throws {
        var entries: [(serverID: Int?, guestID: Int, objects: [Int])] = []
        if let root = issuedKeys?.first(where: { $0.id == keyID }) {
            guard revoked || (root.state == .active && root.pending == nil) else { throw GuestCrypto.Failure.invalidEnvelope }
            entries.append((root.keyID, root.guestID, revoked ? root.numberIDs : (root.effectiveNumberIDs ?? root.numberIDs)))
        } else if let leaf = delegatedKeys?.first(where: { $0.id == keyID }) {
            guard revoked || (leaf.state == .ready && leaf.revocationPending != true) else { throw GuestCrypto.Failure.invalidEnvelope }
            entries.append((leaf.keyID, leaf.guestID, leaf.numberIDs))
        } else { throw GuestCrypto.Failure.invalidEnvelope }
        var visited = Set(entries.compactMap(\.serverID))
        for _ in 0..<5 {
            let descendants = (delegatedKeys ?? []).filter {
                visited.contains($0.parentKeyID) && !visited.contains($0.keyID) && (revoked || ($0.state == .ready && $0.revocationPending != true))
            }
            if descendants.isEmpty { break }
            for child in descendants { visited.insert(child.keyID); entries.append((child.keyID, child.guestID, child.numberIDs)) }
        }
        var records = bleRevocations ?? []
        for entry in entries {
            for object in objects ?? [] where object.kind == "ble" && (revoked || (object.pending == nil && object.available != false)) && entry.objects.contains(object.numberID ?? -1) && (restrictingObjectIDs == nil || restrictingObjectIDs!.contains(object.numberID ?? -1)) {
                guard let did = object.bleDeviceID, let wrapped = object.wrappedBLESecret else { throw GuestCrypto.Failure.invalidKey }
                if !forceVersion, let current = records.first(where: { $0.deviceID == did && Int($0.guestID) == entry.guestID }), current.revoked == revoked,
                   try current.verify(ownerSecret: GuestCrypto.decrypt(key: masterKey, envelope: wrapped)) { continue }
                let previous = records.filter { $0.deviceID == did }.map(\.version).max() ?? 0
                guard epoch > 0, epoch < UInt64(UInt32.max), previous < UInt32.max else { throw GuestCrypto.Failure.invalidEnvelope }
                let version = max(UInt32(epoch), previous + 1)
                let record = try BLERevocation(deviceID: did, guestID: UInt16(entry.guestID), version: version, revoked: revoked,
                    ownerSecret: GuestCrypto.decrypt(key: masterKey, envelope: wrapped))
                records = try BLERevocation.merge([record], into: records, limit: 2000)
            }
        }
        bleRevocations = records
    }
}

public extension OwnerAccount {
    mutating func reconcileBLERestoration() throws {
        var pending: [UUID] = []
        for id in bleRestorePending ?? [] {
            let scope = bleRestoreObjectIDs?[id.uuidString].map(Set.init)
            if let root = issuedKeys?.first(where: { $0.id == id }) {
                guard root.state != .revoked else { continue }
                guard root.state == .active, root.pending == nil else { pending.append(id); continue }
                try queueBLEDecision(keyID: id, revoked: false, restrictingObjectIDs: scope)
                if (delegatedKeys ?? []).contains(where: { $0.rootID == id && $0.state == .awaiting }) { pending.append(id) }
            } else if let leaf = delegatedKeys?.first(where: { $0.id == id }) {
                guard leaf.state != .revoked, leaf.revocationPending != true else { continue }
                guard leaf.state == .ready else { pending.append(id); continue }
                try queueBLEDecision(keyID: id, revoked: false, restrictingObjectIDs: scope)
            }
        }
        bleRestorePending = pending
        let remaining = Set(pending.map { $0.uuidString })
        bleRestoreObjectIDs = bleRestoreObjectIDs?.filter { remaining.contains($0.key) }

    }
}

public extension OwnerAccount {
    mutating func scheduleBLERestoration(keyID: UUID, objectIDs: Set<Int>? = nil) {
        let alreadyFull = (bleRestorePending ?? []).contains(keyID) && bleRestoreObjectIDs?[keyID.uuidString] == nil
        bleRestorePending = Array(Set((bleRestorePending ?? []) + [keyID]))
        if let objectIDs, !alreadyFull {
            var scopes = bleRestoreObjectIDs ?? [:]
            scopes[keyID.uuidString] = Array(Set(scopes[keyID.uuidString] ?? []).union(objectIDs)).sorted()
            bleRestoreObjectIDs = scopes
        } else if objectIDs == nil { bleRestoreObjectIDs?.removeValue(forKey: keyID.uuidString) }
    }
}
