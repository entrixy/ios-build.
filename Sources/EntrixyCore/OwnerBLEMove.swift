import Foundation

/// Registry migration only. The radio secret, controller DID and object UUID
/// never change, and no pairing or actuator packet is produced by this flow.
public struct OwnerBLEMove: Codable, Equatable, Identifiable {
    public enum Phase: String, Codable { case createPrepared, createSent, removePrepared, removeSent, rollbackPrepared, rollbackSent, ready }
    public let id: UUID
    public let objectID: UUID
    public let sourceNumberID: Int
    public let deviceID: UInt32
    public let cipher: String
    public let destination: String
    public private(set) var destinationNumberID: Int?
    public private(set) var phase: Phase
    public init(object: OwnerObject, destination: String) throws {
        guard object.kind == "ble", let number = object.numberID, let did = object.bleDeviceID,
              object.pending == nil, object.available != false else { throw GuestCrypto.Failure.invalidEnvelope }
        id = UUID(); objectID = object.id; sourceNumberID = number; deviceID = did; cipher = object.cipher
        self.destination = try GuestInvite.normalizeServer(destination); phase = .createPrepared
    }
    public func validate() throws {
        guard sourceNumberID > 0, deviceID != 0, !cipher.isEmpty, cipher.utf8.count <= 1_048_576,
              destination == (try GuestInvite.normalizeServer(destination)),
              destinationNumberID.map({ $0 > 0 }) ?? true,
              [.createPrepared,.createSent].contains(phase) == (destinationNumberID == nil) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public func request() throws -> Data {
        switch phase {
        case .createPrepared: return try JSONSerialization.data(withJSONObject: ["type":"ble","data_cipher":cipher], options:.sortedKeys)
        case .removePrepared: return try JSONSerialization.data(withJSONObject: ["id":sourceNumberID], options:.sortedKeys)
        case .rollbackPrepared:
            guard let destinationNumberID else { throw GuestCrypto.Failure.invalidEnvelope }
            return try JSONSerialization.data(withJSONObject:["id":destinationNumberID],options:.sortedKeys)
        default: throw GuestCrypto.Failure.invalidEnvelope
        }
    }
    public mutating func markSent() throws {
        switch phase { case .createPrepared: phase = .createSent; case .removePrepared: phase = .removeSent
        case .rollbackPrepared: phase = .rollbackSent; default: throw GuestCrypto.Failure.invalidEnvelope }
    }
    public mutating func rejectedCreation() throws {
        guard phase == .createSent else { throw GuestCrypto.Failure.invalidEnvelope }
        phase = .createPrepared
    }
    public mutating func acceptedCreation(numberID: Int) throws {
        guard phase == .createSent, numberID > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        destinationNumberID = numberID; phase = .removePrepared
    }
    @discardableResult public mutating func reconcileDestination(_ snapshot: OwnerSnapshot) throws -> Bool {
        if phase == .createSent {
            let rows = snapshot.rows.filter { $0["type"] as? String == "ble" && $0["data_cipher"] as? String == cipher }
            guard rows.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
            if let row = rows.first { try acceptedCreation(numberID: OwnerObject.replyID(row["id"])) }
        }
        guard let destinationNumberID else { return false }
        return snapshot.rows.contains { $0["id"] as? Int == destinationNumberID && $0["type"] as? String == "ble" && $0["data_cipher"] as? String == cipher }
    }
    public mutating func reconcileSource(_ snapshot: OwnerSnapshot) {
        if (phase == .removePrepared || phase == .removeSent), !snapshot.rows.contains(where: { $0["id"] as? Int == sourceNumberID }) { phase = .ready }
    }
    public mutating func retryIdempotentRemoval() throws {
        switch phase {
        case .removeSent: phase = .removePrepared
        case .rollbackSent: phase = .rollbackPrepared
        default: throw GuestCrypto.Failure.invalidEnvelope
        }
    }
    public mutating func rollback() throws {
        guard phase == .removePrepared || phase == .removeSent, destinationNumberID != nil else { throw GuestCrypto.Failure.invalidEnvelope }
        phase = .rollbackPrepared
    }
}

public extension OwnerObject {
    func transferred(from sourceKey: Data, to destinationKey: Data, numberID: Int, revision: Int64?) throws -> OwnerObject {
        guard kind == "ble", pending == nil, let wrappedBLESecret, let bleDeviceID else { throw GuestCrypto.Failure.invalidEnvelope }
        let key = try GuestCrypto.decrypt(key: sourceKey, envelope: wrappedKey)
        let radio = try GuestCrypto.decrypt(key: sourceKey, envelope: wrappedBLESecret)
        var result = try OwnerObject(importing: id, numberID: numberID, kind: "ble", cipher: cipher,
            wrappedKey: GuestCrypto.encrypt(key: destinationKey, plaintext: key), masterKey: destinationKey,
            bleSecret: radio, bleDeviceID: bleDeviceID, localPolicy: localPolicy)
        result.available = true; result.revision = revision
        result.avatarCipher = avatarCipher; result.localConfiguration = localConfiguration; result.bleProofs = bleProofs
        try result.validate(masterKey: destinationKey); return result
    }
}

public extension OwnerIssuedKey {
    /// Strip a lost object from this SAME guest's encrypted bundle. Remaining
    /// token bytes/expiry, guest identity and other objects are copied intact.
    mutating func removeMovedObject(_ number: Int, masterKey: Data) throws {
        guard numberIDs.contains(number), pending == nil, keyID != nil else { throw GuestCrypto.Failure.invalidEnvelope }
        var bundle = try bundle(masterKey: masterKey)
        let name = String(number)
        for field in ["obj_keys","obj_keys_prev","obj_epoch","templates","sock","cams"] {
            if let raw = bundle[field] {
                guard var values = raw as? [String:Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                values.removeValue(forKey:name); bundle[field] = values
            }
        }
        for field in ["obj_ids","streams"] {
            if let raw = bundle[field] {
                guard let values = raw as? [Int] else { throw GuestCrypto.Failure.invalidEnvelope }
                bundle[field] = values.filter { $0 != number }
            }
        }
        if let raw = bundle["ble"] {
            guard let rows = raw as? [[String:Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
            bundle["ble"] = rows.filter { $0["id"] as? Int != number }
        }
        let secret = try secrets(masterKey:masterKey)
        let cipher = try GuestCrypto.encrypt(key:secret.bundleKey,plaintext:JSONSerialization.data(withJSONObject:bundle,options:.sortedKeys))
        numberIDs.removeAll { $0 == number }; bundleCipher = cipher
        grantedAccess?.removeValue(forKey:name); access?.removeValue(forKey:name); requestedAccess?.removeValue(forKey:name)
        automationTemplates?.removeValue(forKey:name); streamAllowed?.removeAll { $0 == number }
        bleTokenLifetimes?.removeValue(forKey:name); callPreferences?.removeValue(forKey:name)
        effectiveNumberIDs = effectiveNumberIDs?.filter { $0 != number }
        pending = state == .revoked ? nil : .keyEdit; sent = false
    }
}

public extension OwnerAccount {
    func isMoving(_ object: UUID) -> Bool { (bleMoves ?? []).contains { $0.objectID == object } }
}

public extension OwnerBLEMove {
    /// Validate both authenticated registries before atomically replacing local
    /// owner/catalog state. A failed storage write leaves the original untouched.
    func committed(source: OwnerAccount, destination target: OwnerAccount, sourceSnapshot: OwnerSnapshot,
                   destinationSnapshot: OwnerSnapshot, preferences: ObjectCatalogPreferences) throws -> (OwnerAccount,OwnerAccount,ObjectCatalogPreferences) {
        guard phase == .ready, source.server != target.server, target.server == destination,
              let destinationNumberID, !sourceSnapshot.rows.contains(where: { $0["id"] as? Int == sourceNumberID }),
              let row = destinationSnapshot.rows.first(where: { $0["id"] as? Int == destinationNumberID && $0["type"] as? String == "ble" && $0["data_cipher"] as? String == cipher }),
              let object = source.objects?.first(where: { $0.id == objectID && $0.numberID == sourceNumberID && $0.cipher == cipher && $0.pending == nil }),
              !(target.objects ?? []).contains(where: { $0.id == objectID || $0.numberID == destinationNumberID || $0.bleDeviceID == deviceID }) else { throw GuestCrypto.Failure.invalidEnvelope }
        var from = source, to = target, order = preferences
        let moved = try object.transferred(from:source.masterKey,to:target.masterKey,numberID:destinationNumberID,revision:(row["data_cipher_revision"] as? NSNumber)?.int64Value)
        let roots = (from.issuedKeys ?? []).filter { $0.numberIDs.contains(sourceNumberID) }.map(\.id)
        let leaves = (from.delegatedKeys ?? []).filter { $0.numberIDs.contains(sourceNumberID) }.map(\.id)
        for id in roots + leaves { try from.queueBLEDecision(keyID:id,revoked:true,restrictingObjectIDs:[sourceNumberID]) }
        for index in (from.issuedKeys ?? []).indices where from.issuedKeys![index].numberIDs.contains(sourceNumberID) {
            let id = from.issuedKeys![index].id
            try from.issuedKeys![index].removeMovedObject(sourceNumberID,masterKey:from.masterKey)
            from.queueKeySettings(id)
            from.issuedKeys![index].objectSettingsToken = from.bundleRefreshQueue?[id.uuidString]
        }
        try from.reconcileIssuedKeys(sourceSnapshot)
        for index in (from.delegatedKeys ?? []).indices where from.delegatedKeys![index].numberIDs.contains(sourceNumberID) {
            from.delegatedKeys![index].confirmedNumberIDs.removeAll { $0 == sourceNumberID }
            if let row = sourceSnapshot.keyRows.first(where: { $0["id"] as? Int == from.delegatedKeys![index].keyID }),
               (row["enabled"] as? NSNumber)?.boolValue == false { from.delegatedKeys![index].state = .revoked }
            else { from.delegatedKeys![index].state = .unavailable }
        }
        var archived = object; archived.available = false
        from.objects?.removeAll { $0.id == objectID }
        from.bleArchivedObjects = (from.bleArchivedObjects ?? []).filter { $0.id != objectID } + [archived]
        to.objects = (to.objects ?? []) + [moved]
        let pairings = (from.blePairings ?? []).filter { $0.objectID == objectID }
        for pairing in pairings {
            guard !(to.blePairings ?? []).contains(where: { $0.deviceID == pairing.deviceID || $0.id == pairing.id }) else { throw GuestCrypto.Failure.invalidEnvelope }
            to.blePairings = (to.blePairings ?? []) + [try BLEPairingRecord(transferring:pairing,from:source.masterKey,to:target.masterKey)]
        }
        from.blePairings?.removeAll { $0.objectID == objectID }
        from.bleMoves?.removeAll { $0.id == id }
        let old = ObjectReference.owned(server:source.server,objectID:objectID), new = ObjectReference.owned(server:target.server,objectID:objectID)
        order.order = order.order.filter { $0 != new }.map { $0 == old ? new : $0 }
        try order.validate(); try from.validate(); try to.validate()
        return (from,to,order)
    }
}
