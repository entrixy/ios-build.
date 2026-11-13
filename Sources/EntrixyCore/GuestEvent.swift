import Foundation

/// Read-only protocol events. Display labels still come exclusively from owner ciphertext.
public enum GuestEvent {
    case snapshot(Data, paused: Bool)
    case numbers(Data)
    case mode(paused: Bool)
    case unavailable(String)
    case avatarUnavailable(Int)
    case avatar(numberID: Int, envelope: String)
    case action(Data)
    case message(String)
    case bleRevocations(Data)
    case passVouch
    case ignore

    public static let terminalReasons: Set<String> = [
        "bad_key", "auth", "already_bound", "expired", "needs_new_key", "org_key",
        "disabled", "evicted", "not_found", "revoked"
    ]

    public static func decode(_ data: Data) throws -> GuestEvent {
        guard data.count <= 1_048_576,
              let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else {
            throw GuestAPI.Failure(status: 0, code: "invalid_response")
        }
        switch type {
        case "guest_ok", "numbers_update":
            guard message["numbers"] is [[String: Any]] else {
                throw GuestAPI.Failure(status: 0, code: "invalid_response")
            }
            if type == "guest_ok" { return .snapshot(data, paused: message["mode"] as? String == "off") }
            return .numbers(data)
        case "message":
            guard let cipher = message["cipher"] as? String, !cipher.isEmpty, cipher.utf8.count <= 4096 else { return .ignore }
            return .message(cipher)
        case "ble_revokes": return .bleRevocations(data)
        case "pass_vouch": return .passVouch
        case "mode_update":
            guard let mode = message["mode"] as? String, ["off", "on", "auto"].contains(mode) else { return .ignore }
            return .mode(paused: mode == "off")
        case "avatar_data":
            guard let id = message["number_id"] as? Int, id > 0 else { return .ignore }
            guard let cipher = message["avatar_cipher"] as? String, !cipher.isEmpty else { return .avatarUnavailable(id) }
            return .avatar(numberID: id, envelope: cipher)
        case "host_status", "devices_online", "device_online", "obj_state_update", "sock_challenge", "call_status", "device_status":
            return .action(data)
        case "error":
            if let id = message["number_id"] as? Int, id > 0 { return .action(data) }
            let reason = message["reason"] as? String ?? "server_error"
            if ["device_offline", "host_offline", "forbidden", "rate_limit", "rate_limited"].contains(reason) { return .action(data) }
            if terminalReasons.contains(reason) { return .unavailable(reason) }
            throw GuestAPI.Failure(status: 0, code: reason)
        default: return .ignore
        }
    }
}
