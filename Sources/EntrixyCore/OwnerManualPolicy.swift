import Foundation
import CoreFoundation

/// Owner's local rules are distinct from the template issued to a guest.
public struct OwnerManualPolicy {
    public let authentication: String?
    public let confirmation: Bool
    public let blockedReason: String?
    public init(_ bytes: Data?) throws {
        guard let bytes else { authentication = nil; confirmation = false; blockedReason = nil; return }
        guard bytes.count <= 65536, let template = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        func flag(_ field: String) throws -> Bool {
            guard let value = template[field] else { return false }
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw GuestCrypto.Failure.invalidEnvelope }
            return n.boolValue
        }
        if try flag("auth_on") {
            guard let mode = template["auth"] as? String, ["pin", "biometric", "either"].contains(mode) else { throw GuestCrypto.Failure.invalidEnvelope }
            authentication = mode
        } else { authentication = nil }
        confirmation = try flag("confirm_on") || flag("confirm")
        let mode = template["mode"] as? String ?? "any"
        guard ["any", "all"].contains(mode) else { throw GuestCrypto.Failure.invalidEnvelope }
        let channels = try ["geo_on", "wifi_on", "time_on", "ble_on"].filter { try flag($0) }
        blockedReason = mode == "all" && channels.count > 1 ? "Совместная проверка условий этого объекта пока недоступна." : nil
    }
}
