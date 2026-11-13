import Foundation

/// Typed Android SharedPreferences export. Original bytes are retained so a
/// migration adapter can never silently erase data it has not mapped yet.
public struct AndroidBackupDocument: Codable {
    public enum Preference: Codable, Equatable {
        case string(String), boolean(Bool), integer(Int32), long(Int64), float(Float), strings([String])
        private enum Keys: String, CodingKey { case t, v }
        public init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: Keys.self)
            switch try value.decode(String.self, forKey: .t) {
            case "s":
                let text = try value.decode(String.self, forKey: .v)
                guard text.utf8.count <= 8_388_608 else { throw GuestCrypto.Failure.invalidEnvelope }
                self = .string(text)
            case "b": self = .boolean(try value.decode(Bool.self, forKey: .v))
            case "i": self = .integer(try value.decode(Int32.self, forKey: .v))
            case "l": self = .long(try value.decode(Int64.self, forKey: .v))
            case "f":
                let number = try value.decode(Float.self, forKey: .v)
                guard number.isFinite else { throw GuestCrypto.Failure.invalidEnvelope }
                self = .float(number)
            case "ss":
                let items = try value.decode([String].self, forKey: .v)
                guard items.count <= 50000, Set(items).count == items.count,
                      items.allSatisfy({ $0.utf8.count <= 65536 }) else { throw GuestCrypto.Failure.invalidEnvelope }
                self = .strings(items)
            default: throw GuestCrypto.Failure.invalidEnvelope
            }
        }
        public func encode(to encoder: Encoder) throws {
            var value = encoder.container(keyedBy: Keys.self)
            switch self {
            case .string(let text): try value.encode("s", forKey: .t); try value.encode(text, forKey: .v)
            case .boolean(let flag): try value.encode("b", forKey: .t); try value.encode(flag, forKey: .v)
            case .integer(let number): try value.encode("i", forKey: .t); try value.encode(number, forKey: .v)
            case .long(let number): try value.encode("l", forKey: .t); try value.encode(number, forKey: .v)
            case .float(let number): try value.encode("f", forKey: .t); try value.encode(number, forKey: .v)
            case .strings(let items): try value.encode("ss", forKey: .t); try value.encode(items, forKey: .v)
            }
        }
    }
    private struct Payload: Decodable {
        let app: String
        let ver: Int
        let created: Int64
        let device: String
        let count: Int
        let entries: [String: Preference]
    }
    public struct Owner: Codable, Equatable {
        public let server: String
        public let credentials: OwnerCredentials
    }
    public struct Guest: Codable, Equatable {
        public let localID: Int
        public let server: String
        public let userKey: String
        public let label: String
    }
    public let original: Data
    public let created: Date
    public let device: String
    public let entries: [String: Preference]
    public init(_ plain: Data) throws {
        guard !plain.isEmpty, plain.count <= BackupEnvelope.maxPayloadSize else { throw GuestCrypto.Failure.invalidEnvelope }
        let payload = try JSONDecoder().decode(Payload.self, from: plain)
        guard payload.app == "entrixy", payload.ver == 1, payload.created > 0, payload.created <= 253_402_300_799,
              payload.count == payload.entries.count, (1...50000).contains(payload.count), payload.device.utf8.count <= 512,
              payload.entries.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { throw GuestCrypto.Failure.invalidEnvelope }
        original = plain; created = Date(timeIntervalSince1970: Double(payload.created))
        device = payload.device; entries = payload.entries
        _ = try masterKey()
        _ = try owners()
        let guests = try guests()
        if !guests.isEmpty { _ = try sourceSeed(required: true) }
    }
    private enum CodingKeys: String, CodingKey { case original }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self = try AndroidBackupDocument(value.decode(Data.self, forKey: .original))
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(original, forKey: .original)
    }
    public func validate() throws {
        let reparsed = try AndroidBackupDocument(original)
        guard reparsed.entries == entries, reparsed.created == created, reparsed.device == device else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public func string(_ key: String) throws -> String? {
        guard let entry = entries[key] else { return nil }
        guard case .string(let value) = entry else { throw GuestCrypto.Failure.invalidEnvelope }
        return value
    }
    public func integer(_ key: String) throws -> Int64? {
        guard let entry = entries[key] else { return nil }
        switch entry {
        case .integer(let value): return Int64(value)
        case .long(let value): return value
        default: throw GuestCrypto.Failure.invalidEnvelope
        }
    }
    public func sourceSeed(required: Bool) throws -> String? {
        guard let seed = try string("backup_src_seed") else {
            if required { throw GuestCrypto.Failure.invalidKey }; return nil
        }
        guard seed.utf8.count == 64, seed.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GuestCrypto.Failure.invalidKey }
        return seed
    }
    public func masterKey() throws -> Data? {
        guard let encoded = try string("e2ee_master_key") else { return nil }
        let key = try GuestCrypto.decodeBase64URL(encoded)
        guard key.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return key
    }
    public func jsonArray(_ key: String, limit: Int = 1000) throws -> [[String: Any]] {
        guard let raw = try string(key) else { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]], rows.count <= limit else { throw GuestCrypto.Failure.invalidEnvelope }
        return rows
    }
    public func primaryServer() throws -> String {
        try GuestInvite.normalizeServer(string("backup_server_host") ?? "entrixy.com")
    }
    public func owners() throws -> [Owner] {
        let rows = try jsonArray("owner_accounts", limit: 100)
        var owners: [Owner] = []
        if entries["owner_accounts"] == nil {
            let id = try string("device_id"), secret = try string("device_secret")
            guard (id == nil) == (secret == nil) else { throw GuestCrypto.Failure.invalidKey }
            if let id, let secret { owners.append(Owner(server: try primaryServer(), credentials: try OwnerCredentials(deviceID: id, deviceSecret: secret))) }
        } else {
            for row in rows {
                guard let host = row["host"] as? String, let id = row["id"] as? String, let secret = row["secret"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
                owners.append(Owner(server: try GuestInvite.normalizeServer(host), credentials: try OwnerCredentials(deviceID: id, deviceSecret: secret)))
            }
        }
        guard Set(owners.map(\.server)).count == owners.count else { throw GuestCrypto.Failure.invalidEnvelope }
        return owners
    }
    public func guests() throws -> [Guest] {
        var guests: [Guest] = []
        for row in try jsonArray("guest_keys") {
            let id = try OwnerObject.replyID(row["id"])
            guard let key = row["key"] as? String, key.utf8.count == 32,
                  try GuestCrypto.decodeBase64URL(key).count == 24 else { throw GuestCrypto.Failure.invalidKey }
            let host = row["host"] as? String ?? "entrixy.com"
            let label = row["label"] as? String ?? ""
            guard label.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
            guests.append(Guest(localID: id, server: try GuestInvite.normalizeServer(host), userKey: key, label: label))
        }
        guard Set(guests.map(\.localID)).count == guests.count,
              Set(guests.map { $0.server + ":" + $0.userKey }).count == guests.count else { throw GuestCrypto.Failure.invalidEnvelope }
        return guests
    }
    public func unwrap(_ name: String) throws -> Data? {
        guard let wrapped = try string(name) else { return nil }
        guard let master = try masterKey() else { throw GuestCrypto.Failure.invalidKey }
        return try GuestCrypto.decrypt(key: master, envelope: wrapped)
    }
    public func invitation(for guest: Guest) throws -> GuestInvite? {
        guard let key = try unwrap("e2ee_in_guest_\(guest.localID)") else { return nil }
        guard key.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return try GuestInvite.parse("https://\(guest.server)/key#\(guest.userKey)\(GuestCrypto.base64URL(key))")
    }
    public func recipient(for guest: Guest) throws -> BundleKeySeal.Recipient? {
        let group = try string("share_grp_\(guest.localID)")
        let pub: String?, wrapped: String?
        if let group, let sharedPublic = try string("share_pub_\(group)"), let sharedPrivate = try string("share_priv_\(group)") {
            pub = sharedPublic; wrapped = sharedPrivate
        } else {
            pub = try string("dlg_pub_\(guest.localID)"); wrapped = try string("dlg_priv_\(guest.localID)")
        }
        guard (pub == nil) == (wrapped == nil) else { throw GuestCrypto.Failure.invalidKey }
        guard let pub, let wrapped else { return nil }
        guard let master = try masterKey(), let privateKey = String(data: try GuestCrypto.decrypt(key: master, envelope: wrapped), encoding: .utf8) else { throw GuestCrypto.Failure.invalidKey }
        let recipient = BundleKeySeal.Recipient(privateKey: privateKey, publicKey: pub)
        try BundleKeySeal.validate(recipient)
        return recipient
    }
    public func objectReference(localID: Int, fallbackServer: String? = nil) throws -> (server: String, numberID: Int) {
        guard localID > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        if let raw = try string("obj_alias") {
            guard let map = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] else { throw GuestCrypto.Failure.invalidEnvelope }
            if let ref = map[String(localID)] {
                guard let separator = ref.lastIndex(of: "|"), let id = Int(ref[ref.index(after: separator)...]), id > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
                let server = try GuestInvite.normalizeServer(String(ref[..<separator]))
                if let fallbackServer, server != (try GuestInvite.normalizeServer(fallbackServer)) { throw GuestCrypto.Failure.invalidEnvelope }
                return (server, id)
            }
        }
        return (try GuestInvite.normalizeServer(fallbackServer ?? primaryServer()), localID)
    }
}
