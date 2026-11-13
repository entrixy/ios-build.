import Foundation
import CoreFoundation

extension OwnerIssuedKey {
    init(restoring id: UUID, material: AndroidOwnerKeyMaterial, owner: OwnerAccount, row: [String: Any], guestID: Int,
         userKey: String, bundleKey: Data, cipher: String, numberIDs: [Int]) throws {
        self.id = id; label = material.label; self.numberIDs = numberIDs.sorted(); self.guestID = guestID
        func flag(_ raw: Any?) throws -> Bool {
            guard let raw, !(raw is NSNull) else { return false }
            if let n = raw as? NSNumber, n == 0 || n == 1 { return n.boolValue }
            if let text = raw as? String, text == "0" || text == "1" { return text == "1" }
            throw GuestCrypto.Failure.invalidEnvelope
        }
        nativeOnly = try flag(row["native_only"])
        wrappedSecrets = try GuestCrypto.encrypt(key: owner.masterKey, plaintext: JSONSerialization.data(withJSONObject:
            ["user_key": userKey, "bundle_key": GuestCrypto.base64URL(bundleKey)], options: .sortedKeys))
        bundleCipher = cipher; keyID = material.serverKeyID; pending = nil; sent = false; state = .unavailable
        // Scope is authenticated by the original AES bundle. Delegation limits
        // were not sealed in Android preferences, so require explicit review.
        grantedAccess = try Dictionary(uniqueKeysWithValues: numberIDs.map { (String($0), try KeyObjectAccess(nativeOnly: nativeOnly, depth: 0, pool: 1)) })
        accessNeedsReview = true
        try validate(masterKey: owner.masterKey)
    }
}

public extension OwnerAccount {
    /// Recover existing roots with original secrets only. Missing/foreign bundle
    /// material stays in androidKeys; it never causes replacement key generation.
    @discardableResult
    mutating func reconcileAndroidKeys(_ snapshot: OwnerSnapshot) throws -> Int {
        var recovered = issuedKeys ?? [], remaining: [AndroidOwnerKeyMaterial] = []
        var failures: [String: String] = [:]
        var used = Set(recovered.map(\.guestID))
        used.formUnion((delegatedKeys ?? []).map(\.guestID))
        used.formUnion((bleRevocations ?? []).map { Int($0.guestID) })
        used.formUnion((androidKeys ?? []).compactMap(\.guestID))
        used.formUnion(reservedGuestIDs ?? [])
        var count = 0
        for material in androidKeys ?? [] {
            guard let user = material.userKey else {
                remaining.append(material); failures[String(material.serverKeyID)] = "delegated_review"; continue
            }
            if recovered.contains(where: { $0.keyID == material.serverKeyID }) {
                // Retain an unmatched slot rather than silently dropping it.
                let existing = recovered.first { $0.keyID == material.serverKeyID }!
                let key = try existing.secrets(masterKey: masterKey)
                guard key.userKey == user, material.guestID == nil || material.guestID == existing.guestID else { throw GuestCrypto.Failure.invalidKey }
                if let wrapped = material.wrappedBundleKey { guard try GuestCrypto.decrypt(key: masterKey, envelope: wrapped) == key.bundleKey else { throw GuestCrypto.Failure.invalidKey } }
                continue
            }
            do {
                guard let row = snapshot.keyRows.first(where: { ($0["id"] as? Int) == material.serverKeyID }) else {
                    remaining.append(material); failures[String(material.serverKeyID)] = "not_found"; continue
                }
                let publicKey = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: user).publicKey.rawRepresentation)
                guard row["sign_pub"] as? String == publicKey,
                      let wrapped = material.wrappedBundleKey, let cipher = row["bundle_cipher"] as? String, !cipher.isEmpty else { throw GuestCrypto.Failure.invalidKey }
                let key = try GuestCrypto.decrypt(key: masterKey, envelope: wrapped)
                guard key.count == 32, let bundle = try JSONSerialization.jsonObject(with: GuestCrypto.decrypt(key: key, envelope: cipher)) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                guard bundle["obj_ids"] == nil || bundle["obj_ids"] is [Any], bundle["ble"] == nil || bundle["ble"] is [[String: Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
                let network = try (bundle["obj_ids"] as? [Any] ?? []).map { try OwnerObject.replyID($0) }
                let bluetooth = bundle["ble"] as? [[String: Any]] ?? []
                let ble = try bluetooth.map { try BLEGuestGrant(row: $0) }
                let ids = network + ble.map(\.objectID)
                guard !ids.isEmpty, Set(ids).count == ids.count else { throw GuestCrypto.Failure.invalidEnvelope }
                let allowed = try ((row["number_ids"] as? [Any] ?? []) + (row["ble_ids"] as? [Any] ?? [])).map { try OwnerObject.replyID($0) }
                guard Set(allowed).count == allowed.count, Set(allowed).isSubset(of: Set(ids)),
                      Set(ids).isSubset(of: Set((objects ?? []).compactMap(\.numberID))) else { throw GuestCrypto.Failure.invalidEnvelope }
                if let map = bundle["obj_keys"] as? [String: String] {
                    for number in network {
                        guard let object = objects?.first(where: { $0.numberID == number && $0.kind != "ble" }),
                              let encoded = map[String(number)],
                              try GuestCrypto.decodeBase64URL(encoded) == GuestCrypto.decrypt(key: masterKey, envelope: object.wrappedKey) else { throw GuestCrypto.Failure.invalidKey }
                    }
                } else if !network.isEmpty { throw GuestCrypto.Failure.invalidEnvelope }
                var guestIDs = Set(ble.map { Int($0.guestID) })
                if let raw = bundle["sock"] {
                    guard let map = raw as? [String: [String: Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
                    for value in map.values { guestIDs.insert(try SocketCredential(json: value).guestID) }
                }
                if let did = material.guestID { guestIDs.insert(did) }
                guard guestIDs.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                let did: Int
                if let original = guestIDs.first {
                    guard !recovered.contains(where: { $0.guestID == original }), !(delegatedKeys ?? []).contains(where: { $0.guestID == original }) else { throw GuestCrypto.Failure.invalidEnvelope }
                    did = original
                } else {
                    guard let available = (1...65535).first(where: { !used.contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
                    did = available // Bookkeeping only; no physical grant is issued.
                }
                used.insert(did)
                let digest = String(GuestCrypto.hash(Data(("entrixy-android-key-v1|" + server + "|" + String(material.serverKeyID) + "|" + user).utf8)).prefix(32))
                var uuid = ""
                for (index, character) in digest.enumerated() { if [8,12,16,20].contains(index) { uuid.append("-") }; uuid.append(character) }
                let restored = try OwnerIssuedKey(restoring: UUID(uuidString: uuid)!, material: material, owner: self, row: row,
                    guestID: did, userKey: user, bundleKey: key, cipher: cipher, numberIDs: ids)
                recovered.append(restored); count += 1
            } catch {
                remaining.append(material); failures[String(material.serverKeyID)] = "verification_required"
            }
        }
        issuedKeys = recovered; androidKeys = remaining; androidKeyFailures = failures
        return count
    }
}
