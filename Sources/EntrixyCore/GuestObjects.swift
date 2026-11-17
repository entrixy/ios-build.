import Foundation

public struct GuestObject: Codable, Equatable, Identifiable {
    public let id: String
    public let numberID: Int
    public let kind: String
    public let label: String
    public var avatarType: String? = nil
}

public enum GuestObjects {
    public static func decryptAvatar(bundle: Data, numberID: Int, envelope: String) throws -> Data {
        guard envelope.utf8.count <= 1_048_576,
              let contents = try JSONSerialization.jsonObject(with: bundle) as? [String: Any] else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        for name in ["obj_keys", "obj_keys_prev"] {
            guard let encoded = (contents[name] as? [String: String])?[String(numberID)],
                  let key = try? GuestCrypto.decodeBase64URL(encoded),
                  let bytes = try? GuestCrypto.decrypt(key: key, envelope: envelope),
                  bytes.count <= 524_288 else { continue }
            return bytes
        }
        throw GuestCrypto.Failure.invalidEnvelope
    }

    /// Only decrypt owner-provided ciphertext. A server-provided plaintext label is not trusted.
    public static func decode(bundle: Data, snapshot: Data) throws -> [GuestObject] {
        guard let b = try JSONSerialization.jsonObject(with: bundle) as? [String: Any],
              let s = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        if ServerSessionPolicy.shared.networkPrivacyEnforced { _ = try PrivacyNetwork.decode(b["net_block"]) }
        else if let blocked = b["net_block"] as? [Any], !blocked.isEmpty {
            throw GuestAPI.Failure(status: 0, code: "network_policy_unsupported")
        }
        let current = b["obj_keys"] as? [String: String] ?? [:]
        let previous = b["obj_keys_prev"] as? [String: String] ?? [:]
        var objects: [GuestObject] = []
        let ble = b["ble"] as? [[String: Any]] ?? []
        let bleIDs = Set(ble.compactMap { $0["id"] as? Int })
        for row in s["numbers"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? Int, id > 0 else { continue }
            if row["type"] as? String == "ble", bleIDs.contains(id) { continue }
            var label = "Название недоступно"
            var avatarType: String?
            if let cipher = row["data_cipher"] as? String {
                for encoded in [current[String(id)], previous[String(id)]].compactMap({ $0 }) {
                    guard let key = try? GuestCrypto.decodeBase64URL(encoded),
                          let clear = try? GuestCrypto.decrypt(key: key, envelope: cipher),
                          let data = try? JSONSerialization.jsonObject(with: clear) as? [String: Any] else { continue }
                    if let value = data["label"] as? String, !value.isEmpty { label = value }
                    avatarType = data["avatar_type"] as? String
                    break
                }
            }
            objects.append(GuestObject(id: "n:\(id)", numberID: id, kind: row["type"] as? String ?? "device", label: label, avatarType: avatarType))
        }
        for row in ble {
            guard let id = row["id"] as? Int, id > 0 else { continue }
            objects.append(GuestObject(id: "b:\(id)", numberID: id, kind: "ble", label: row["label"] as? String ?? "Bluetooth", avatarType: row["avatar_type"] as? String))
        }
        return objects
    }
}
