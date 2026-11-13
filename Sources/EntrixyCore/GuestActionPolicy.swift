import Foundation
import CoreFoundation

/// All local authorization settings come from owner-encrypted metadata.
public struct GuestActionPolicy {
    public let kind: String
    public let deviceID: Int?
    public let credential: SocketCredential?
    public let serverWebhook: Bool
    public let confirmation: Bool
    public let authentication: String?
    public let toggles: Bool
    public let blockedReason: String?

    public static func decodeBLE(bundle: Data, numberID: Int, epoch: UInt64) throws -> (policy: GuestActionPolicy, grant: BLEGuestGrant) {
        guard let contents = try JSONSerialization.jsonObject(with: bundle) as? [String: Any],
              let rows = contents["ble"] as? [[String: Any]],
              rows.count <= 1000 else { throw GuestCrypto.Failure.invalidEnvelope }
        let ids = try rows.map { try OwnerObject.replyID($0["id"]) }
        guard Set(ids).count == ids.count, let row = rows.first(where: { ($0["id"] as? Int) == numberID }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let grant = try BLEGuestGrant(row: row)
        guard grant.isValid(at: epoch) else { throw BLECommandSession.Failure.expired }
        guard row["tpl"] == nil || row["tpl"] is [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        let template = row["tpl"] as? [String: Any] ?? [:]
        func flag(_ field: String) throws -> Bool {
            guard let raw = template[field] else { return false }
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw GuestCrypto.Failure.invalidEnvelope }
            return n.boolValue
        }
        let auth: String?
        if try flag("auth_on") {
            guard let value = template["auth"] as? String, ["pin", "biometric", "either"].contains(value) else { throw GuestCrypto.Failure.invalidEnvelope }
            auth = value
        } else { auth = nil }
        var blocked: String?
        if let raw = contents["net_block"] {
            guard let networks = raw as? [Any] else { throw GuestCrypto.Failure.invalidEnvelope }
            if !networks.isEmpty { blocked = "Сетевые ограничения ключа пока не поддерживаются на iOS." }
        }
        let mode = template["mode"] as? String ?? "any"
        guard ["any", "all"].contains(mode) else { throw GuestCrypto.Failure.invalidEnvelope }
        let channels = try ["geo_on", "wifi_on", "time_on", "ble_on"].filter { try flag($0) }
        if mode == "all" && channels.count > 1 { blocked = "Совместная проверка условий этого объекта пока не поддерживается на iOS." }
        let confirmation = try flag("confirm_on") || flag("confirm")
        return (GuestActionPolicy(kind: "ble", deviceID: nil, credential: nil, serverWebhook: false,
            confirmation: confirmation, authentication: auth, toggles: true, blockedReason: blocked), grant)
    }

    public static func decode(bundle: Data, snapshot: Data, numberID: Int) throws -> GuestActionPolicy {
        guard let b = try JSONSerialization.jsonObject(with: bundle) as? [String: Any],
              let s = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
              let row = (s["numbers"] as? [[String: Any]])?.first(where: { $0["id"] as? Int == numberID }),
              let kind = row["type"] as? String, ["device", "call", "webhook"].contains(kind),
              let cipher = row["data_cipher"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
        var metadata: [String: Any]?
        for field in ["obj_keys", "obj_keys_prev"] {
            if let encoded = (b[field] as? [String: String])?[String(numberID)],
               let key = try? GuestCrypto.decodeBase64URL(encoded),
               let bytes = try? GuestCrypto.decrypt(key: key, envelope: cipher),
               let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { metadata = object; break }
        }
        guard let metadata else { throw GuestCrypto.Failure.invalidEnvelope }
        var template: [String: Any] = [:]
        if let raw = b["templates"] {
            guard let all = raw as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
            if let raw = all[String(numberID)] {
                guard let object = raw as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                template = object
            }
        }
        func flag(_ field: String) throws -> Bool {
            guard let value = template[field] else { return false }
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw GuestCrypto.Failure.invalidEnvelope }
            return n.boolValue
        }
        let authentication: String?
        if try flag("auth_on") {
            guard let mode = template["auth"] as? String, ["pin", "biometric", "either"].contains(mode) else { throw GuestCrypto.Failure.invalidEnvelope }
            authentication = mode
        } else { authentication = nil }
        let confirm = try flag("confirm_on") || flag("confirm")
        let serverWebhook = try flag("server_webhook") && kind == "webhook"
        var blocked: String?
        if let raw = b["net_block"] {
            guard let rules = raw as? [Any] else { throw GuestCrypto.Failure.invalidEnvelope }
            if !rules.isEmpty { blocked = "Сетевые ограничения этого ключа пока не поддерживаются на iOS." }
        }
        let channels = try ["geo_on", "wifi_on", "time_on", "ble_on"].filter { try flag($0) }
        let mode = template["mode"] as? String ?? "any"
        guard ["any", "all"].contains(mode) else { throw GuestCrypto.Failure.invalidEnvelope }
        // Android allows manual override in ANY mode (and with only one channel).
        // Unsupported combined conditions must never turn into unconditional access.
        if mode == "all" && channels.count > 1 { blocked = "Совместная проверка условий этого объекта пока не поддерживается на iOS." }
        if ["time_from", "time_to"].contains(where: { (row[$0] as? String).map { !$0.isEmpty } == true }) {
            blocked = "Временные ограничения этого объекта пока не поддерживаются на iOS."
        }
        var credential: SocketCredential?
        if kind == "device" {
            if let json = (b["sock"] as? [String: Any])?[String(numberID)] as? [String: Any] {
                credential = try SocketCredential(json: json)
            } else { blocked = "Не получен защищённый пропуск контроллера." }
        }
        return GuestActionPolicy(kind: kind, deviceID: row["device_id"] as? Int, credential: credential,
                                 serverWebhook: serverWebhook, confirmation: confirm, authentication: authentication,
                                 toggles: (metadata["wh_toggle"] as? Int) == 1, blockedReason: blocked)
    }
}
