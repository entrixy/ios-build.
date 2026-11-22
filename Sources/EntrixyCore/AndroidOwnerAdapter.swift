import Foundation
import CoreFoundation

/// Local translation only. The caller persists the complete source archive and
/// a migration plan before owner claim. Imported objects stay unavailable until
/// an authenticated snapshot decrypts with their original object keys.
public enum AndroidOwnerAdapter {
    /// Shared by imported owner objects and their local catalogue preferences.
    public static func objectID(server: String, numberID: Int) -> UUID {
        let hash = GuestCrypto.hash(Data(("entrixy-android-object-v1|" + server + "|" + String(numberID)).utf8))
        let value = String(hash.prefix(32)), offsets = [8,12,16,20]
        var text = ""
        for (i,c) in value.enumerated() { if offsets.contains(i) { text.append("-") }; text.append(c) }
        return UUID(uuidString:text)!
    }
    public static func owners(from document: AndroidBackupDocument) throws -> [OwnerAccount] {
        try document.validate()
        let accounts = try document.owners()
        let numbers = try document.jsonArray("host_numbers"), bluetooth = try document.jsonArray("ble_objects")
        let originalMaster = try document.masterKey()
        if originalMaster == nil {
            // A lazily initialized Android installation may never have had a
            // master. Existing wrapped secrets without it are corruption.
            guard !document.entries.keys.contains(where: { $0.hasPrefix("e2ee_obj_") || $0.hasPrefix("e2ee_guest_") }) else { throw GuestCrypto.Failure.invalidKey }
        }
        let master = originalMaster ?? GuestCrypto.randomBytes(count: 32)
        var result: [String: OwnerAccount] = [:]
        for source in accounts {
            var owner = try OwnerAccount(importing: source.server, masterKey: master, credentials: source.credentials)
            var settings = OwnerServerSettings()
            settings.accessCode = try document.string("access_code_" + source.server) ?? ""
            settings.accountEmail = source.email
            try settings.validate(); owner.serverSettings = settings
            owner.androidKeys = try document.ownerKeyMaterial(server: source.server, masterKey: master)
            result[source.server] = owner
        }
        func secret(_ encoded: Any?) throws -> Data? {
            guard let encoded, !(encoded is NSNull) else { return nil }
            guard let text = encoded as? String, let key = Data(base64Encoded: text), key.count == 32 else { throw GuestCrypto.Failure.invalidKey }
            return key
        }
        let bleIDs = Set(try bluetooth.map { try OwnerObject.replyID($0["id"]) })
        guard bleIDs.count == bluetooth.count else { throw GuestCrypto.Failure.invalidEnvelope }
        var importedIDs = Set<String>()
        for row in numbers + bluetooth.map({ row in var row = row; row["type"] = "ble"; return row }) {
            let localID = try OwnerObject.replyID(row["id"])
            guard row["type"] == nil || row["type"] is String else { throw GuestCrypto.Failure.invalidEnvelope }
            let kind = row["type"] as? String ?? "call"
            guard ["call", "webhook", "device", "ble"].contains(kind) else { throw GuestCrypto.Failure.invalidEnvelope }
            if kind == "ble", row["secret"] == nil, bleIDs.contains(localID) { continue }
            let ref = try document.objectReference(localID: localID, fallbackServer: row["host"] as? String)
            guard importedIDs.insert(ref.server + ":" + String(ref.numberID)).inserted else { throw GuestCrypto.Failure.invalidEnvelope }
            if result[ref.server] == nil { result[ref.server] = try OwnerAccount(importing: ref.server, masterKey: master, credentials: nil) }
            let wrapped = try document.string("e2ee_obj_\(localID)")
            let sourceCipher = try document.string("e2ee_obj_blob_\(localID)")
            let previousWrapped = try document.string("e2ee_obj_prev_\(localID)")
            let pendingCipher = try document.string("pending_rotated_cipher_\(localID)")
            let epoch = try document.integer("e2ee_obj_epoch_\(localID)") ?? 1
            guard epoch > 0, epoch <= Int32.max else { throw GuestCrypto.Failure.invalidEnvelope }
            guard wrapped != nil || sourceCipher == nil else { throw GuestCrypto.Failure.invalidKey }
            let objectKey: Data
            if let wrapped { objectKey = try GuestCrypto.decrypt(key: master, envelope: wrapped); guard objectKey.count == 32 else { throw GuestCrypto.Failure.invalidKey } }
            else { objectKey = GuestCrypto.randomBytes(count: 32) }
            let metadata: [String: Any]
            if let candidate = pendingCipher ?? sourceCipher {
                guard let fields = try JSONSerialization.jsonObject(with: GuestCrypto.decrypt(key: objectKey, envelope: candidate)) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                metadata = fields
            } else { metadata = ["label": row["label"] as? String ?? "Объект", "avatar_type": "preset:3"] }
            var routing: [String: String] = [:]
            if kind == "webhook" {
                routing["webhook_mode"] = row["whMode"] as? String ?? "phone"
                if let value = try document.string("local_wh_url_\(localID)") ?? row["whUrl"] as? String { routing["webhook_url"] = value }
                if let value = try document.string("local_wh_sec_\(localID)") ?? row["whSec"] as? String { routing["webhook_secret"] = value }
            }
            if kind == "device", let did = row["did"] { routing["device_id_ref"] = String(try OwnerObject.replyID(did)) }
            var bleSecret: Data?, bleDID: UInt32?
            if kind == "ble" {
                bleSecret = try secret(row["secret"])
                if bleSecret == nil, let encoded = metadata["ble_secret"] as? String {
                    bleSecret = try GuestCrypto.decodeBase64URL(encoded)
                }
                guard let did = row["did"] ?? metadata["ble_did"] else { throw GuestCrypto.Failure.invalidEnvelope }
                // Reuse strict signed/unsigned DID parsing without accepting a
                // plaintext secret as an unauthenticated advertisement.
                guard let n = did as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let parsed = Int64(n.stringValue), n == NSNumber(value: parsed),
                      (-2_147_483_648...4_294_967_295).contains(parsed) else { throw GuestCrypto.Failure.invalidEnvelope }
                bleDID = parsed < 0 ? UInt32(bitPattern: Int32(parsed)) : UInt32(parsed)
            }
            let phone = kind == "call" ? try document.string("local_phone_\(localID)") ?? row["phone"] as? String ?? metadata["phone"] as? String : nil
            let socket = kind == "device" ? try secret(document.string("sock_secret_\(localID)")) : nil
            let policy: Data?
            if let raw = try document.string(kind == "ble" ? "ble_templates" : "guest_templates") {
                guard let templates = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                if let value = templates[kind == "ble" ? String(localID) : "k0n\(localID)"] {
                    guard value is [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                    policy = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
                } else { policy = nil }
            } else { policy = nil }
            let inFlight = pendingCipher != nil && sourceCipher != pendingCipher
                && sourceCipher.map { (try? GuestCrypto.decrypt(key: objectKey, envelope: $0)) == nil } == true
            if inFlight { guard previousWrapped != nil, sourceCipher != nil, wrapped != nil, epoch > 1, kind != "ble" else { throw GuestCrypto.Failure.invalidEnvelope } }
            var object = try OwnerObject(importing: objectID(server: ref.server, numberID: ref.numberID), numberID: ref.numberID,
                kind: kind, cipher: sourceCipher ?? GuestCrypto.encrypt(key: objectKey, plaintext: JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)),
                wrappedKey: (inFlight ? previousWrapped : wrapped) ?? GuestCrypto.encrypt(key: master, plaintext: objectKey), masterKey: master,
                phone: phone, routing: routing, socketSecret: socket, bleSecret: bleSecret, bleDeviceID: bleDID, localPolicy: policy,
                previousWrappedKey: inFlight ? nil : previousWrapped, keyEpoch: Int(epoch) - (inFlight ? 1 : 0))
            if inFlight, let wrapped, let pendingCipher, let sourceCipher {
                object.keyRotation = OwnerObjectKeyRotation(wrappedKey: wrapped, sourceCipher: sourceCipher,
                    cipher: pendingCipher, avatarCipher: nil, epoch: Int(epoch), sent: true)
            } else if pendingCipher != nil { object.cipher = pendingCipher! }
            if let queued = document.entries["pending_object_rotations"] {
                guard case .strings(let ids) = queued else { throw GuestCrypto.Failure.invalidEnvelope }
                object.keyRotationQueued = !inFlight && pendingCipher == nil && ids.contains(String(localID))
            }
            object.localConfiguration = try document.ownerLocalConfiguration(localID:localID)
            result[ref.server]!.objects = (result[ref.server]!.objects ?? []) + [object]
            if let bleDID, let bleSecret {
                let signedDID = Int32(bitPattern: bleDID)
                let raw = try document.string("blerev_\(signedDID)") ?? document.string("blerev_\(bleDID)")
                if let raw {
                    guard let decisions = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: [String: Any]], decisions.count <= 2000 else { throw GuestCrypto.Failure.invalidEnvelope }
                    var records: [BLERevocation] = []
                    for (guest, decision) in decisions {
                        guard let gid = Int(guest), gid > 0, let version = decision["v"], let revoked = decision["r"], let sig = decision["s"] else { throw GuestCrypto.Failure.invalidEnvelope }
                        let record = try BLERevocation(row: ["lock_did": Int64(signedDID), "guest_id": gid, "version": version, "revoked": revoked, "sig": sig])
                        guard try record.verify(ownerSecret: bleSecret) else { throw GuestCrypto.Failure.invalidKey }
                        // Android's old "written" marker is a GATT ACK, not an
                        // authenticated application receipt. Keep it pending.
                        records.append(record)
                    }
                    result[ref.server]!.bleRevocations = try BLERevocation.merge(records, into: result[ref.server]!.bleRevocations ?? [], limit: 2000)
                }
            }
        }
        // Android allocates DIDs across the entire installation. Preserve
        // reservations across hosts, including tokens from a moved controller.
        var reserved = Set<Int>()
        for name in document.entries.keys where name.hasPrefix("ble_guest_did_") {
            guard let value = try document.integer(name), (1...65535).contains(value) else { throw GuestCrypto.Failure.invalidEnvelope }
            reserved.insert(Int(value))
        }
        for name in document.entries.keys where name.hasPrefix("blerev_") {
            guard let raw = try document.string(name), let map = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
            for name in map.keys { guard let id = Int(name), (1...65535).contains(id) else { throw GuestCrypto.Failure.invalidEnvelope }; reserved.insert(id) }
        }
        let defaults = try document.guestDefaults()
        let privacy = try document.networkPrivacyPreferences()
        for host in Array(result.keys) {
            result[host]!.reservedGuestIDs = reserved.sorted()
            result[host]!.hostLabel = defaults.ownerName
            if document.entries["blocked_wifi"] != nil { result[host]!.privacyNetworks = privacy.own }
        }
        let owners = result.values.sorted { $0.server < $1.server }
        guard owners.count <= 100 else { throw GuestCrypto.Failure.invalidEnvelope }
        for owner in owners { try owner.validate() }
        return owners
    }
}
