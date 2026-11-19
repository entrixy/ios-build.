import Foundation

/// One exact metadata replacement, durable before sharing or publication. The
/// active object stays readable with its current key until a snapshot confirms
/// this ciphertext. This queue never contains or repeats an actuator command.
public struct OwnerObjectKeyRotation: Codable, Equatable {
    public let wrappedKey: String
    public let sourceCipher: String
    public let cipher: String
    public let avatarCipher: String?
    public let epoch: Int
    public var sent: Bool
}

public extension OwnerObject {
    var hasKeyRotation: Bool { keyRotation != nil || keyRotationQueued == true }

    mutating func prepareKeyRotation(masterKey: Data) throws {
        guard keyRotationQueued == true, keyRotation == nil, pending == nil,
              numberID != nil, revision != nil, available != false, kind != "ble" else { return }
        let epoch = keyEpoch ?? 1
        guard epoch > 0, epoch < Int32.max else { throw GuestCrypto.Failure.invalidEnvelope }
        let fresh = GuestCrypto.randomBytes(count: 32)
        let clear = try GuestCrypto.decrypt(key: GuestCrypto.decrypt(key: masterKey, envelope: wrappedKey), envelope: cipher)
        let image = try avatar(masterKey: masterKey)
        keyRotation = try OwnerObjectKeyRotation(
            wrappedKey: GuestCrypto.encrypt(key: masterKey, plaintext: fresh), sourceCipher: cipher,
            cipher: GuestCrypto.encrypt(key: fresh, plaintext: clear),
            avatarCipher: image.map { try GuestCrypto.encrypt(key: fresh, plaintext: $0) },
            epoch: epoch + 1, sent: false)
        keyRotationQueued = false
    }

    func validateKeyRotation(masterKey: Data) throws {
        guard (keyEpoch ?? 1) > 0, (keyEpoch ?? 1) <= Int32.max else { throw GuestCrypto.Failure.invalidEnvelope }
        if let previousWrappedKey {
            guard try GuestCrypto.decrypt(key: masterKey, envelope: previousWrappedKey).count == 32 else { throw GuestCrypto.Failure.invalidKey }
        }
        guard let rotation = keyRotation else { return }
        guard kind != "ble", numberID != nil, pending == nil,
              rotation.epoch == (keyEpoch ?? 1) + 1,
              rotation.sourceCipher.utf8.count <= 1_048_576, rotation.cipher.utf8.count <= 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
        let fresh = try GuestCrypto.decrypt(key: masterKey, envelope: rotation.wrappedKey)
        let current = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedKey)
        guard fresh.count == 32, fresh != current,
              try GuestCrypto.decrypt(key: fresh, envelope: rotation.cipher) == GuestCrypto.decrypt(key: current, envelope: rotation.sourceCipher) else {
            throw GuestCrypto.Failure.invalidKey
        }
        if let image = rotation.avatarCipher {
            guard image.utf8.count <= 1_048_576,
                  try GuestCrypto.decrypt(key: fresh, envelope: image).count <= 524_288 else { throw GuestCrypto.Failure.invalidEnvelope }
        }
    }

    mutating func acceptKeyRotation(cipher confirmed: String) {
        guard let rotation = keyRotation, rotation.sent, rotation.cipher == confirmed else { return }
        previousWrappedKey = wrappedKey; wrappedKey = rotation.wrappedKey
        keyEpoch = rotation.epoch; cipher = rotation.cipher; avatarCipher = rotation.avatarCipher
        keyRotation = nil // A second confirmed access loss keeps its queued flag.
    }
}

public extension OwnerAccount {
    var hasObjectKeyRotations: Bool { (objects ?? []).contains(where: \.hasKeyRotation) }

    /// Compare only previously acknowledged scopes. A paused root keeps its
    /// object keys on Android; a revoked root or removed object does not.
    mutating func queueObjectKeyRotations(after previous: OwnerAccount) {
        var removed = Set<Int>()
        for old in previous.issuedKeys ?? [] where old.state != .revoked {
            guard let current = issuedKeys?.first(where: { $0.id == old.id }) else { continue }
            let before = Set(old.effectiveNumberIDs ?? [])
            if current.state == .revoked { removed.formUnion(before) }
            else if current.pending == nil, let scope = current.effectiveNumberIDs { removed.formUnion(before.subtracting(scope)) }
        }
        for old in previous.delegatedKeys ?? [] where old.state != .revoked {
            guard let current = delegatedKeys?.first(where: { $0.id == old.id }) else { continue }
            if current.state == .revoked { removed.formUnion(old.numberIDs) }
            else { removed.formUnion(Set(old.numberIDs).subtracting(current.numberIDs)) }
        }
        for i in (objects ?? []).indices where objects![i].kind != "ble" && removed.contains(objects![i].numberID ?? -1) {
            objects![i].keyRotationQueued = true
        }
    }

    mutating func prepareObjectKeyRotations() throws {
        for i in (objects ?? []).indices where objects![i].keyRotationQueued == true && objects![i].keyRotation == nil {
            // Preserve imported epochs even when an older owner record omitted
            // the optional epoch field but its authenticated bundles retained it.
            var epoch = objects![i].keyEpoch ?? 1
            let number = String(objects![i].numberID ?? -1)
            for key in issuedKeys ?? [] {
                let contents = try key.bundle(masterKey: masterKey)
                epoch = max(epoch, (contents["obj_epoch"] as? [String: Int])?[number] ?? 1)
            }
            objects![i].keyEpoch = epoch
            try objects![i].prepareKeyRotation(masterKey: masterKey)
            if objects![i].keyRotation != nil, let numberID = objects![i].numberID { queueObjectSettings(numberID: numberID) }
        }
        // Imported or interrupted rotations may predate the refresh queue.
        // Queue a stale bundle once; never regenerate the token on every sync.
        for object in objects ?? [] {
            guard let rotation = object.keyRotation, let number = object.numberID else { continue }
            let next = GuestCrypto.base64URL(try GuestCrypto.decrypt(key: masterKey, envelope: rotation.wrappedKey))
            for key in issuedKeys ?? [] where key.state != .revoked && key.bundleRecipientNumberIDs.contains(number) && bundleRefreshQueue?[key.id.uuidString] == nil {
                let bundle = try key.bundle(masterKey: masterKey)
                if (bundle["obj_keys"] as? [String: String])?[String(number)] != next { queueKeySettings(key.id) }
            }
        }
    }

    /// The server must acknowledge the new AND previous keys for EVERY remaining
    /// recipient before the encrypted object changes. Unknown Android slots or
    /// an unresolved create/edit deliberately hold publication rather than
    /// silently cutting off a guest. Paused keys also receive refreshed bundles.
    func canPublishKeyRotation(objectID: UUID, snapshot: OwnerSnapshot) throws -> Bool {
        guard let object = objects?.first(where: { $0.id == objectID }), let number = object.numberID,
              let rotation = object.keyRotation, object.pending == nil, object.available != false,
              object.cipher == rotation.sourceCipher,
              snapshot.rows.contains(where: { ($0["id"] as? Int) == number && $0["data_cipher"] as? String == object.cipher }) else { return false }
        let next = GuestCrypto.base64URL(try GuestCrypto.decrypt(key: masterKey, envelope: rotation.wrappedKey))
        let prior = GuestCrypto.base64URL(try GuestCrypto.decrypt(key: masterKey, envelope: object.wrappedKey))
        func updated(_ bundle: [String: Any]) -> Bool {
            (bundle["obj_keys"] as? [String: String])?[String(number)] == next &&
            (bundle["obj_keys_prev"] as? [String: String])?[String(number)] == prior &&
            (bundle["obj_epoch"] as? [String: Int])?[String(number)] == rotation.epoch
        }
        for row in snapshot.keyRows {
            let enabled: Bool
            if let value = row["enabled"] as? NSNumber, value == 0 || value == 1 { enabled = value.boolValue }
            else if let value = row["enabled"] as? String, value == "0" || value == "1" { enabled = value == "1" }
            else { return false }
            guard let rawScope = row["number_ids"] as? [Any] else { return false }
            let scope = try rawScope.map { try OwnerObject.replyID($0) }
            guard enabled, scope.contains(number) else { continue }
            let id = try OwnerObject.replyID(row["id"])
            if let key = issuedKeys?.first(where: { $0.keyID == id }) {
                guard key.state != .revoked, key.pending == nil,
                      row["bundle_cipher"] as? String == key.bundleCipher,
                      updated(try key.bundle(masterKey: masterKey)) else { return false }
            } else if let key = delegatedKeys?.first(where: { $0.keyID == id }) {
                guard key.bundleDeliveryConfirmed == true, key.revocationPending != true,
                      row["bundle_cipher"] as? String == key.bundleCipher,
                      updated(try key.bundle(masterKey: masterKey)) else { return false }
            } else { return false }
        }
        // A create with an unknown outcome may already exist on the server.
        for key in issuedKeys ?? [] where key.state != .revoked && key.bundleRecipientNumberIDs.contains(number) {
            guard key.pending == nil, key.keyID != nil, updated(try key.bundle(masterKey: masterKey)) else { return false }
        }
        return true
    }
}
