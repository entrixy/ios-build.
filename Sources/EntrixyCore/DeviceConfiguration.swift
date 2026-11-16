import Foundation

public struct DeviceConfigurationCredentials: Codable, Equatable {
    public let deviceID: Int
    public let key: String
    public let secret: String
    public init(deviceID: Int, key: String, secret: String) throws {
        guard deviceID > 0, [key,secret].allSatisfy({ $0.utf8.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        self.deviceID = deviceID; self.key = key; self.secret = secret
    }
    public func code(server: String) throws -> String {
        let host = try GuestInvite.normalizeServer(server)
        return "ENTX-DEV:" + key + secret + (host == "entrixy.com" ? "" : "@" + host)
    }
}

public extension OwnerObject {
    mutating func acceptDeviceRegistration(id: Int, key: String, secret: String, masterKey: Data) throws {
        guard pending == .deviceRegister, sent, numberID == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        let material = try DeviceConfigurationCredentials(deviceID: id, key: key, secret: secret)
        let encrypted = try GuestCrypto.encrypt(key: masterKey, plaintext: JSONEncoder().encode(material))
        wrappedDeviceCredentials = encrypted; routing["device_id_ref"] = String(id)
        pending = .create; sent = false
    }
    func deviceCredentials(masterKey: Data) throws -> DeviceConfigurationCredentials? {
        guard let wrappedDeviceCredentials else { return nil }
        guard kind == "device" else { throw GuestCrypto.Failure.invalidEnvelope }
        let value = try JSONDecoder().decode(DeviceConfigurationCredentials.self,
            from: GuestCrypto.decrypt(key: masterKey, envelope: wrappedDeviceCredentials))
        let checked = try DeviceConfigurationCredentials(deviceID: value.deviceID, key: value.key, secret: value.secret)
        guard routing["device_id_ref"] == String(checked.deviceID) else { throw GuestCrypto.Failure.invalidEnvelope }
        return checked
    }
    mutating func prepareSocketBinding(masterKey: Data) throws -> String {
        guard kind == "device", pending != .delete else { throw GuestCrypto.Failure.invalidEnvelope }
        let secret: Data
        if let wrappedSocketSecret { secret = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedSocketSecret) }
        else {
            secret = GuestCrypto.randomBytes(count: 32)
            wrappedSocketSecret = try GuestCrypto.encrypt(key: masterKey, plaintext: secret)
        }
        guard secret.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return "ENTX-BIND:" + secret.map { String(format:"%02x",$0) }.joined()
    }
}
