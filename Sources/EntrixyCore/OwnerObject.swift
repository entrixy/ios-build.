import Foundation
import CoreFoundation

public enum OwnerOperation: String, Codable {
    case create = "number_add", update = "number_update", delete = "number_delete", claim = "device_claim"
    case keyCreate = "key_create", keyEdit = "key_edit", keyMode = "key_set_mode", keyRevoke = "key_revoke"
    case hostClaim = "host_claim", messageSend = "message_send"
}

/// Stored only inside the device-only Keychain. Object keys are wrapped by K_master.
public struct OwnerObject: Codable, Identifiable, Equatable {
    public let id: UUID
    public var numberID: Int?
    public let kind: String
    public var cipher: String
    public let wrappedKey: String
    public var revision: Int64?
    public var available: Bool?
    public var pending: OwnerOperation?
    public var sent: Bool
    public var routing: [String: String]
    public var claimCode: String?
    public var localPhone: String?
    public var wrappedSocketSecret: String?
    public var wrappedBLESecret: String?
    public var bleDeviceID: UInt32?
    public var localPolicy: Data?
    public var bleProofs: [String]?
    /// Physical BLE ownership is proved by the paired secret, independently of
    /// the server registration/metadata acknowledgement. Delete intent hides it.
    public var ownerCardAvailable: Bool {
        if kind == "ble" { return wrappedBLESecret != nil && bleDeviceID != nil && pending != .delete }
        return numberID != nil && pending == nil && available != false
    }

    public init(masterKey: Data, label: String, kind: String, phone: String = "", url: String = "", secret: String = "", claimCode: String = "") throws {
        guard ["call", "webhook", "device"].contains(kind), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
        let normalizedPhone = phone.filter { !" -()".contains($0) }
        if kind == "call" {
            let digits = normalizedPhone.hasPrefix("+") ? normalizedPhone.dropFirst() : normalizedPhone[...]
            guard !digits.isEmpty, normalizedPhone.utf8.count <= 64,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        if kind == "webhook" {
            guard let u = URLComponents(string: url), u.scheme == "https", u.host != nil,
                  u.user == nil, u.password == nil, u.fragment == nil, !secret.isEmpty, secret.utf8.count <= 1024 else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        let code = claimCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if kind == "device" { guard !code.isEmpty, code.utf8.count <= 128 else { throw GuestCrypto.Failure.invalidEnvelope } }
        let key = GuestCrypto.randomBytes(count: 32)
        // K_obj is shared with guests. Phone numbers and webhook secrets must stay owner-only.
        localPhone = kind == "call" ? normalizedPhone : nil
        let metadata: [String: Any] = ["label": label.trimmingCharacters(in: .whitespacesAndNewlines), "avatar_type": "preset:3"]
        id = UUID()
        self.kind = kind
        wrappedKey = try GuestCrypto.encrypt(key: masterKey, plaintext: key)
        cipher = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys))
        routing = kind == "webhook" ? ["webhook_mode": "server", "webhook_url": url, "webhook_secret": secret] : [:]
        pending = kind == "device" ? .claim : .create
        self.claimCode = kind == "device" ? code : nil
        sent = false
    }

    public init(importing id: UUID, numberID: Int, kind: String, cipher: String, wrappedKey: String,
                masterKey: Data, phone: String? = nil, routing: [String: String] = [:],
                socketSecret: Data? = nil, bleSecret: Data? = nil, bleDeviceID: UInt32? = nil, localPolicy: Data? = nil) throws {
        self.id = id; self.numberID = numberID; self.kind = kind; self.cipher = cipher; self.wrappedKey = wrappedKey
        self.localPhone = phone; self.routing = routing; self.pending = nil; self.sent = false; self.available = false
        if let socketSecret {
            guard socketSecret.count == 32 else { throw GuestCrypto.Failure.invalidKey }
            wrappedSocketSecret = try GuestCrypto.encrypt(key: masterKey, plaintext: socketSecret)
        }
        if let bleSecret {
            guard bleSecret.count == 32 else { throw GuestCrypto.Failure.invalidKey }
            wrappedBLESecret = try GuestCrypto.encrypt(key: masterKey, plaintext: bleSecret)
        }
        self.bleDeviceID = bleDeviceID; self.localPolicy = localPolicy
        try validate(masterKey: masterKey)
    }

    public init(pairing: BLEPairingRecord, masterKey: Data) throws {
        try pairing.validate(masterKey: masterKey)
        guard pairing.phase == .confirmed, pairing.objectID == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        let key = GuestCrypto.randomBytes(count: 32)
        id = UUID(); kind = "ble"; wrappedKey = try GuestCrypto.encrypt(key: masterKey, plaintext: key)
        cipher = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject:
            ["label": pairing.label, "avatar_type": "preset:3"], options: .sortedKeys))
        wrappedBLESecret = pairing.wrappedSecret; bleDeviceID = pairing.deviceID
        routing = [:]; pending = .create; sent = false
    }

    public func validate(masterKey: Data) throws {
        guard ["call", "webhook", "device", "ble"].contains(kind), numberID == nil || numberID! > 0,
              pending != nil || (numberID != nil && !sent),
              revision == nil || revision! >= 0,
              Set(routing.keys).isSubset(of: ["webhook_mode", "webhook_url", "webhook_secret", "device_id_ref"]) else { throw GuestCrypto.Failure.invalidEnvelope }
        if pending == .claim { guard claimCode?.isEmpty == false, numberID == nil else { throw GuestCrypto.Failure.invalidEnvelope } }
        if pending == .create { guard numberID == nil else { throw GuestCrypto.Failure.invalidEnvelope } }
        if pending == .update || pending == .delete { guard numberID != nil else { throw GuestCrypto.Failure.invalidEnvelope } }
        _ = try OwnerManualPolicy(localPolicy)
        let proofs = bleProofs ?? []
        guard proofs.count <= 64, Set(proofs).count == proofs.count,
              proofs.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else { throw GuestCrypto.Failure.invalidEnvelope }
        if kind == "ble" {
            guard let wrappedBLESecret, let bleDeviceID, bleDeviceID != 0,
                  try GuestCrypto.decrypt(key: masterKey, envelope: wrappedBLESecret).count == 32 else { throw GuestCrypto.Failure.invalidKey }
        } else if wrappedBLESecret != nil || bleDeviceID != nil { throw GuestCrypto.Failure.invalidEnvelope }
        _ = try metadata(masterKey: masterKey)
    }

    public static func replyID(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let id = value as? Int, id > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        return id
    }

    public func metadata(masterKey: Data) throws -> [String: Any] {
        let key = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedKey)
        let clear = try GuestCrypto.decrypt(key: key, envelope: cipher)
        guard let object = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        return object
    }

    public mutating func rename(_ label: String, masterKey: Data) throws {
        guard pending == nil, numberID != nil, revision != nil, available != false,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
        var contents = try metadata(masterKey: masterKey)
        contents["label"] = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedKey)
        cipher = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: contents, options: .sortedKeys))
        pending = .update
        sent = false
    }

    /// The exact request is persisted before transmission. No private object/master key leaves the device.
    public func request() throws -> Data {
        guard let pending else { throw GuestCrypto.Failure.invalidEnvelope }
        var body: [String: Any] = [:]
        switch pending {
        case .claim:
            guard let claimCode else { throw GuestCrypto.Failure.invalidEnvelope }
            body["claim_code"] = claimCode
        case .create:
            body["type"] = kind
            body["data_cipher"] = cipher
            for (name, value) in routing {
                if name == "device_id_ref" {
                    guard let id = Int(value), id > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
                    body[name] = id
                } else { body[name] = value }
            }
        case .update:
            guard let numberID, let revision else { throw GuestCrypto.Failure.invalidEnvelope }
            body = ["id": numberID, "data_cipher": cipher, "data_cipher_ts_check": revision]
        case .keyCreate, .keyEdit, .keyMode, .keyRevoke, .hostClaim, .messageSend: throw GuestCrypto.Failure.invalidEnvelope
        case .delete:
            guard let numberID else { throw GuestCrypto.Failure.invalidEnvelope }
            body["id"] = numberID
        }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    public mutating func acceptClaim(deviceID: Int) throws {
        guard pending == .claim, sent, deviceID > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        routing["device_id_ref"] = String(deviceID)
        claimCode = nil
        pending = .create
        sent = false
    }
}

public extension OwnerAccount {
    /// Reconcile persisted attempts against a complete authenticated owner snapshot.
    /// Matching the exact randomized ciphertext recovers lost create replies without replay.
    mutating func reconcileObjects(_ snapshot: OwnerSnapshot) throws {
        var updated: [OwnerObject] = []
        var removed = Set<UUID>()
        for var object in objects ?? [] {
            if object.pending == .create && object.sent && object.numberID == nil {
                let matches = snapshot.rows.filter { ($0["data_cipher"] as? String) == object.cipher && ($0["type"] as? String) == object.kind }
                guard matches.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                if let row = matches.first { object.numberID = row["id"] as? Int; object.pending = nil; object.sent = false }
            }
            if let id = object.numberID {
                let row = snapshot.rows.first { ($0["id"] as? Int) == id }
                object.available = row != nil
                if object.pending == .delete && object.sent && row == nil {
                    removed.insert(object.id)
                    if object.kind == "ble" {
                        var archived = object; archived.pending = nil; archived.sent = false; archived.available = false
                        bleArchivedObjects = (bleArchivedObjects ?? []).filter { $0.id != archived.id } + [archived]
                    }
                    continue
                }
                if let row, let cipher = row["data_cipher"] as? String {
                    if object.pending == .update && object.sent && object.cipher == cipher { object.pending = nil; object.sent = false }
                    if object.pending == nil {
                        // Never accept a plaintext label or replace the key after decryption failure.
                        let key = try GuestCrypto.decrypt(key: masterKey, envelope: object.wrappedKey)
                        _ = try GuestCrypto.decrypt(key: key, envelope: cipher)
                        object.cipher = cipher
                        object.revision = (row["data_cipher_revision"] as? NSNumber)?.int64Value
                    }
                }
            }
            updated.append(object)
        }
        objects = updated
        if !removed.isEmpty {
            blePairings = blePairings?.map { record in
                var record = record
                if let id = record.objectID, removed.contains(id) { record.objectID = nil }
                return record
            }
        }
    }
}
