import Foundation

/// Durable before PAIR_DONE. A lost write reply permits only authenticated
/// discovery, never another pairing write with a replacement secret.
public struct BLEPairingRecord: Codable, Identifiable, Equatable {
    public enum Phase: String, Codable { case prepared, sent, confirmed }
    public let id: UUID
    public let peripheralID: UUID
    public let deviceID: UInt32
    public let label: String
    public let peerPublic: Data
    public let packet: Data
    public let wrappedSecret: String
    public private(set) var phase: Phase
    public var objectID: UUID?

    public init(masterKey: Data, peripheralID: UUID, peerPublic: Data, deviceID: UInt32, label: String) throws {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard deviceID != 0, !normalized.isEmpty, normalized.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
        let pair = BLECrypto.makePair()
        let secret = try BLECrypto.pairSecret(privateKey: pair.privateKey, peerPublic: peerPublic)
        id = UUID(); self.peripheralID = peripheralID; self.deviceID = deviceID; self.label = normalized
        self.peerPublic = peerPublic
        packet = try BLECrypto.pairPacket(publicKey: pair.publicKey, deviceID: deviceID)
        wrappedSecret = try GuestCrypto.encrypt(key: masterKey, plaintext: secret)
        phase = .prepared
    }
    public func secret(masterKey: Data) throws -> Data {
        let secret = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedSecret)
        guard secret.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return secret
    }
    public func validate(masterKey: Data) throws {
        guard deviceID != 0, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 512, peerPublic.count == 32, packet.count == 36,
              BLECrypto.unsignedLE(packet.suffix(4)) == UInt64(deviceID),
              objectID == nil || phase == .confirmed else { throw GuestCrypto.Failure.invalidEnvelope }
        _ = try secret(masterKey: masterKey)
    }
    public mutating func markSent() throws {
        guard phase == .prepared else { throw GuestCrypto.Failure.invalidEnvelope }
        phase = .sent
    }
    public mutating func confirm(advertisement: Data, masterKey: Data) throws {
        guard phase == .sent || phase == .confirmed else { throw GuestCrypto.Failure.invalidEnvelope }
        let verified = try BLECrypto.verifyAdvertisement(advertisement, ownerSecret: secret(masterKey: masterKey))
        guard verified.deviceID == deviceID else { throw GuestCrypto.Failure.invalidKey }
        phase = .confirmed
    }
}
