import Foundation

/// Shared validation is exercised without opening a WebSocket. In particular,
/// a guest may request signed decisions, but may never publish owner decisions.
enum ControlFrameValidation {
    static func guest(_ frame: Data) throws -> String {
        let object = try decode(frame, limit: 4096)
        guard let type = object["type"] as? String, ["call", "sock_fire", "ble_revokes_req"].contains(type) else { throw GuestCrypto.Failure.invalidEnvelope }
        if type == "ble_revokes_req", Set(object.keys) != ["type"] { throw GuestCrypto.Failure.invalidEnvelope }
        return String(decoding: frame, as: UTF8.self)
    }
    static func owner(_ frame: Data) throws -> String {
        let object = try decode(frame, limit: 8192)
        guard let type = object["type"] as? String,
              ["host_self_call", "host_self_webhook", "sock_fire", "confirm_response", "call_status", "ble_revoke"].contains(type) else { throw GuestCrypto.Failure.invalidEnvelope }
        if type == "ble_revoke" { _ = try BLERevocation(row: object) }
        return String(decoding: frame, as: UTF8.self)
    }
    private static func decode(_ frame: Data, limit: Int) throws -> [String: Any] {
        guard frame.count <= limit, let json = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        return json
    }
}
