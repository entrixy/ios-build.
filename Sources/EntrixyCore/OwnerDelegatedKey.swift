import Foundation

/// Verified recipient material, never the recipient's signing secret. Prepared blobs
/// are durable before upload so a lost response cannot replace K_guest or socket DID.
public struct OwnerDelegatedKey: Codable, Identifiable, Equatable {
    public enum State: String, Codable { case awaiting, ready, unavailable, revoked }
    public let id: UUID
    public let keyID: Int
    public let parentKeyID: Int
    public let rootID: UUID
    public let signPublic: String
    public let guestPublic: String
    public let vouch: String
    public let guestID: Int
    public let wrappedBundleKey: String
    public var numberIDs: [Int]
    public var access: [String: KeyObjectAccess]
    public var bundleCipher: String
    public var keyCipher: String
    public var state: State
    public var sent: Bool
    public var confirmedNumberIDs: [Int]
    public var label: String
    public var revocationPending: Bool?
    public var revocationSent: Bool?
    /// Exact bundle acknowledgement is separate from whether control is paused.
    public var bundleDeliveryConfirmed: Bool?

    public func validate(masterKey: Data) throws {
        guard keyID > 0, parentKeyID > 0, keyID != parentKeyID, (1...65535).contains(guestID),
              !numberIDs.isEmpty, numberIDs.allSatisfy({ $0 > 0 }), Set(numberIDs).count == numberIDs.count,
              Set(access.keys) == Set(numberIDs.map(String.init)),
              Set(confirmedNumberIDs).isSubset(of: Set(numberIDs)), label.utf8.count <= 1024 else { throw GuestCrypto.Failure.invalidEnvelope }
        for value in access.values { try value.validate() }
        guard try GuestCrypto.decodeBase64URL(signPublic).count == 32,
              try GuestCrypto.decrypt(key: masterKey, envelope: wrappedBundleKey).count == 32,
              keyCipher.hasPrefix("v1:"), Data(base64Encoded: vouch)?.count == 64 else { throw GuestCrypto.Failure.invalidEnvelope }
        _ = try bundle(masterKey: masterKey)
    }
    public func bundle(masterKey: Data) throws -> [String: Any] {
        let key = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedBundleKey)
        guard let json = try JSONSerialization.jsonObject(with: GuestCrypto.decrypt(key: key, envelope: bundleCipher)) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        return json
    }
    public func request() throws -> Data {
        guard state == .awaiting, sent else { throw GuestCrypto.Failure.invalidEnvelope }
        return try JSONSerialization.data(withJSONObject: ["id": keyID, "number_ids": numberIDs, "ble_ids": [Int](),
            "bundle_cipher": bundleCipher, "key_cipher": keyCipher], options: .sortedKeys)
    }
}

private struct DelegationAuthority {
    let keyID: Int
    let rootID: UUID
    let signPublic: Data
    let access: [String: KeyObjectAccess]
    let bundle: [String: Any]
    let label: String
    let ancestors: Set<Int>
    let paused: Bool
}

public extension OwnerAccount {
    /// Server rows alone never establish trust: every recipient is vouched for by
    /// a locally known parent, rooted in a key this owner actually issued.
    @discardableResult
    mutating func reconcileDelegatedKeys(_ snapshot: OwnerSnapshot) throws -> Int {
        var records = delegatedKeys ?? []
        for i in records.indices where records[i].state != .revoked {
            records[i].bundleDeliveryConfirmed = false
            let row = snapshot.keyRows.first { ($0["id"] as? Int) == records[i].keyID }
            if records[i].revocationPending == true && (row == nil || (row?["enabled"] as? NSNumber)?.boolValue == false) {
                records[i].state = .revoked; records[i].revocationPending = false; records[i].revocationSent = false
            } else { records[i].state = .unavailable }
        }
        var authorities: [Int: DelegationAuthority] = [:]
        for key in issuedKeys ?? [] {
            guard let id = key.keyID, key.pending == nil,
                  key.state == .active || key.state == .restricted || (key.state == .paused && hasObjectKeyRotations),
                  let chosen = key.grantedAccess, let effective = key.access else { continue }
            var limits: [String: KeyObjectAccess] = [:]
            for number in key.effectiveNumberIDs ?? key.numberIDs {
                let n = String(number)
                guard let local = chosen[n], let remote = effective[n] else { continue }
                limits[n] = try KeyObjectAccess(nativeOnly: local.nativeOnly || remote.nativeOnly,
                    depth: min(local.depth, remote.depth), pool: min(local.pool, remote.pool))
            }
            let pair = try key.secrets(masterKey: masterKey)
            authorities[id] = DelegationAuthority(keyID: id, rootID: key.id,
                signPublic: try GuestCrypto.signingKey(userKey: pair.userKey).publicKey.rawRepresentation,
                access: limits, bundle: try key.bundle(masterKey: masterKey), label: key.label, ancestors: [id], paused: key.state == .paused)
        }
        let rows = snapshot.keyRows.filter { ($0["parent_key_id"] as? Int ?? 0) > 0 }
        var processed = Set<Int>()
        var accepted = Set<Int>()
        var usedDIDs = Set((issuedKeys ?? []).map(\.guestID))
        usedDIDs.formUnion(records.map(\.guestID))
        usedDIDs.formUnion((bleRevocations ?? []).map { Int($0.guestID) })
        usedDIDs.formUnion(reservedGuestIDs ?? [])
        usedDIDs.formUnion((androidKeys ?? []).compactMap(\.guestID))
        // The protocol permits five levels. Process parents before descendants,
        // irrespective of SELECT order; cycles never acquire an authority.
        for _ in 0..<5 {
            var progress = false
            for row in rows {
                let keyID = try OwnerObject.replyID(row["id"])
                guard !processed.contains(keyID), let parentID = row["parent_key_id"] as? Int,
                      let parent = authorities[parentID], !parent.ancestors.contains(keyID) else { continue }
                guard let sp = row["sign_pub"] as? String, let gp = row["guest_pub"] as? String,
                      let signature = row["vouch_sig"] as? String,
                      (try? DelegationProof.verifyVouch(signature, parentPublic: parent.signPublic, server: server,
                         childID: keyID, signPublic: sp, guestPublic: gp)) == true else { continue }
                processed.insert(keyID); progress = true
                let sameRecipient = records.firstIndex { $0.keyID == keyID && $0.signPublic == sp && $0.guestPublic == gp && $0.parentKeyID == parentID }
                if sameRecipient.map({ records[$0].state == .revoked }) == true { continue }
                let enabled = (row["enabled"] as? NSNumber)?.boolValue == true
                let mode = row["mode"] as? String
                if let index = sameRecipient, records[index].revocationPending == true {
                    if !enabled {
                        records[index].state = .revoked; records[index].revocationPending = false; records[index].revocationSent = false
                    }
                    continue
                }
                guard enabled, mode == "auto" || mode == "notify" || mode == "confirm" || (mode == "off" && hasObjectKeyRotations && sameRecipient != nil) else { continue }
                if parent.paused && sameRecipient == nil { continue }
                let paused = parent.paused || mode == "off"
                guard let networkIDs = row["number_ids"] as? [Any],
                      let limits = try KeyObjectAccess.decode(row["objects"]) else { continue }
                let rawIDs = networkIDs + (row["ble_ids"] as? [Any] ?? [])
                guard !rawIDs.isEmpty else { continue }
                let ids = try rawIDs.map { try OwnerObject.replyID($0) }.sorted()
                guard Set(ids).count == ids.count, Set(limits.keys) == Set(ids.map(String.init)) else { continue }
                // Neither a forged server row nor a cooperating recipient may add
                // another object, increase depth/pool or downgrade inherited app-only.
                guard ids.allSatisfy({ id in
                    guard let inherited = parent.access[String(id)], let requested = limits[String(id)] else { return false }
                    return inherited.depth > 0 && requested.nativeOnly == inherited.nativeOnly
                        && requested.depth < inherited.depth && requested.pool <= max(1, inherited.pool - 1)
                }) else { continue }
                var record: OwnerDelegatedKey
                if let index = sameRecipient {
                    record = records[index]
                    guard record.vouch == signature || (try? DelegationProof.verifyVouch(record.vouch, parentPublic: parent.signPublic,
                        server: server, childID: keyID, signPublic: sp, guestPublic: gp)) == true else { continue }
                    if record.rootID != parent.rootID { continue }
                } else {
                    // A restored Android slot already owns K_guest and possibly
                    // a physical DID. Preserve it until verified recovery; never
                    // replace an existing guest identity with a random key.
                    if (androidKeys ?? []).contains(where: { $0.serverKeyID == keyID }) { continue }
                    guard usedDIDs.count < 65535 else { throw GuestCrypto.Failure.invalidKey }
                    var did: Int
                    repeat { did = Int.random(in: 1...65535) } while usedDIDs.contains(did)
                    usedDIDs.insert(did)
                    let guestKey = GuestCrypto.randomBytes(count: 32)
                    record = OwnerDelegatedKey(id: UUID(), keyID: keyID, parentKeyID: parentID, rootID: parent.rootID,
                        signPublic: sp, guestPublic: gp, vouch: signature, guestID: did,
                        wrappedBundleKey: try GuestCrypto.encrypt(key: masterKey, plaintext: guestKey),
                        numberIDs: ids, access: limits, bundleCipher: "", keyCipher: "", state: .awaiting,
                        sent: false, confirmedNumberIDs: [], label: "Через «\(parent.label)»")
                }
                let sameScope = record.numberIDs == ids && record.access == limits
                let key = try GuestCrypto.decrypt(key: masterKey, envelope: record.wrappedBundleKey)
                // Parent restrictions are copied intact; only this descendant's
                // object keys/socket grants and scope are regenerated.
                let bundle = try OwnerIssuedKey.makeBundle(owner: self, numberIDs: ids, guestID: record.guestID,
                    welcome: "", confirmation: nil, existing: parent.bundle, inheritRestrictions: true)
                let expected = try JSONSerialization.jsonObject(with: bundle) as! [String: Any]
                let old = record.bundleCipher.isEmpty ? nil : try record.bundle(masterKey: masterKey)
                let sameContent = old.map { NSDictionary(dictionary: $0).isEqual(to: expected) } ?? false
                if !sameScope || !sameContent {
                    record.numberIDs = ids; record.access = limits
                    record.bundleCipher = try GuestCrypto.encrypt(key: key, plaintext: bundle)
                    record.keyCipher = try BundleKeySeal.seal(key, recipientPublicKey: gp)
                    record.sent = false; record.confirmedNumberIDs = []
                }
                let confirmed = row["bundle_cipher"] as? String == record.bundleCipher
                    && row["key_cipher"] as? String == record.keyCipher
                    && (row["needs_bundle"] as? NSNumber)?.boolValue == false
                record.state = confirmed ? (paused ? .unavailable : .ready) : .awaiting
                record.bundleDeliveryConfirmed = confirmed
                record.confirmedNumberIDs = confirmed ? ids : []
                if confirmed { record.sent = false }
                for i in records.indices where records[i].keyID == keyID && records[i].id != record.id { records[i].state = .revoked }
                if let index = sameRecipient { records[index] = record } else { records.append(record) }
                if mode != "off" { accepted.insert(keyID) }
                if confirmed {
                    authorities[keyID] = DelegationAuthority(keyID: keyID, rootID: parent.rootID,
                        signPublic: try GuestCrypto.decodeBase64URL(sp), access: limits, bundle: expected,
                        label: record.label, ancestors: parent.ancestors.union([keyID]), paused: paused)
                }
            }
            if !progress { break }
        }
        let prior = delegatedKeys ?? []
        // A revoked/rebound/paused descendant or removed object must not retain
        // an offline token simply because its new server bundle is narrower.
        for old in prior {
            let current = records.first { $0.id == old.id }
            let removed: Set<Int>
            if current == nil || current?.state == .revoked || current?.state == .unavailable {
                removed = Set(old.numberIDs)
            } else { removed = Set(old.numberIDs).subtracting(current!.numberIDs) }
            if !removed.isEmpty { try queueBLEDecision(keyID: old.id, revoked: true, restrictingObjectIDs: removed) }
            if let current, current.state != .revoked, current.revocationPending != true {
                let added = Set(current.numberIDs).subtracting(old.numberIDs)
                if !added.isEmpty { scheduleBLERestoration(keyID: current.id, objectIDs: added) }
            }
        }
        for key in issuedKeys ?? [] where key.state == .paused || key.state == .revoked || key.state == .unavailable {
            try queueBLEDecision(keyID: key.id, revoked: true)
        }
        delegatedKeys = records
        return rows.filter { ($0["enabled"] as? NSNumber)?.boolValue == true && $0["mode"] as? String != "off" }.count - accepted.count
    }
}
