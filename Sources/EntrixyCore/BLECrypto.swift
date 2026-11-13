import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wire format from Android BleCrypto.kt and the ESP32 firmware. No transport or retries.
public enum BLECrypto {
    public static let service = "656e7472-7869-7900-0000-426c45000001"
    public static let nonceCharacteristic = "656e7472-7869-7900-0001-426c45000001"
    public static let fireCharacteristic = "656e7472-7869-7900-0002-426c45000001"
    public static let timeCharacteristic = "656e7472-7869-7900-0003-426c45000001"
    public static let wifiCharacteristic = "656e7472-7869-7900-0004-426c45000001"
    public static let resultCharacteristic = "656e7472-7869-7900-0005-426c45000001"
    public static let revokeCharacteristic = "656e7472-7869-7900-0006-426c45000001"
    public static let pairPublicCharacteristic = "656e7472-7869-7900-00f0-426c45000001"
    public static let pairDoneCharacteristic = "656e7472-7869-7900-00f1-426c45000001"
    public static let companyID: UInt16 = 0x00e0

    public struct Pair: Codable {
        public let privateKey: Data
        public let publicKey: Data
    }
    public static func makePair() -> Pair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Pair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }
    public static func pairSecret(privateKey: Data, peerPublic: Data) throws -> Data {
        guard privateKey.count == 32, peerPublic.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        let shared = try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        guard shared.contains(where: { $0 != 0 }) else { throw GuestCrypto.Failure.invalidKey }
        return hkdf(secret: shared, salt: Data("entrixy-pair-v1".utf8), info: Data("owner-secret".utf8), count: 32)
    }
    public static func pairPacket(publicKey: Data, deviceID: UInt32) throws -> Data {
        guard publicKey.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return publicKey + littleEndian(UInt64(deviceID), count: 4)
    }
    public static func guestKey(ownerSecret: Data, guestID: UInt16) throws -> Data {
        guard ownerSecret.count == 32, guestID != 0 else { throw GuestCrypto.Failure.invalidKey }
        return hkdf(secret: ownerSecret, info: Data("guest".utf8) + littleEndian(UInt64(guestID), count: 2), count: 32)
    }
    public static func stateKey(ownerSecret: Data) throws -> Data {
        guard ownerSecret.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return hkdf(secret: ownerSecret, info: Data("ble-state-v1".utf8), count: 16)
    }
    public static func token(guestID: UInt16, validUntil: UInt32) throws -> Data {
        guard guestID != 0 else { throw GuestCrypto.Failure.invalidKey }
        return littleEndian(UInt64(guestID), count: 2) + littleEndian(UInt64(validUntil), count: 4) + Data([1])
    }
    public static func ownerSignature(ownerSecret: Data, token: Data) throws -> Data {
        guard ownerSecret.count == 32, token.count == 7, token.last == 1 else { throw GuestCrypto.Failure.invalidKey }
        return Data(hmac(ownerSecret, token).prefix(16))
    }
    public static func ownerFire(ownerSecret: Data, nonce: Data) throws -> Data {
        guard ownerSecret.count == 32, nonce.count == 8 else { throw GuestCrypto.Failure.invalidKey }
        return nonce + hmac(ownerSecret, nonce).prefix(16)
    }
    public static func guestFire(token: Data, ownerSignature: Data, guestKey: Data, nonce: Data) throws -> Data {
        guard token.count == 7, token.last == 1, ownerSignature.count == 16, guestKey.count == 32, nonce.count == 8 else { throw GuestCrypto.Failure.invalidKey }
        return token + ownerSignature + nonce + hmac(guestKey, nonce).prefix(16)
    }
    public static func ownerTime(ownerSecret: Data, epochMilliseconds: UInt64, nonce: Data) throws -> Data {
        guard ownerSecret.count == 32, nonce.count == 8 else { throw GuestCrypto.Failure.invalidKey }
        let body = littleEndian(epochMilliseconds, count: 8) + nonce
        return body + hmac(ownerSecret, Data("T".utf8) + body).prefix(16)
    }
    public static func guestTime(token: Data, ownerSignature: Data, guestKey: Data, epochMilliseconds: UInt64, nonce: Data) throws -> Data {
        guard token.count == 7, token.last == 1, ownerSignature.count == 16, guestKey.count == 32, nonce.count == 8 else { throw GuestCrypto.Failure.invalidKey }
        let body = littleEndian(epochMilliseconds, count: 8) + nonce
        return token + ownerSignature + body + hmac(guestKey, Data("T".utf8) + token + body).prefix(16)
    }
    public static func revoke(ownerSecret: Data, guestID: UInt16, version: UInt32, revoked: Bool) throws -> Data {
        guard ownerSecret.count == 32, guestID != 0, version > 0 else { throw GuestCrypto.Failure.invalidKey }
        let body = littleEndian(UInt64(guestID), count: 2) + littleEndian(UInt64(version), count: 4) + Data([revoked ? 1 : 0])
        return body + hmac(ownerSecret, Data("rev".utf8) + body).prefix(16)
    }
    public static func advertisementDeviceID(_ payload: Data) throws -> UInt32 {
        guard payload.count >= 16 else { throw GuestCrypto.Failure.invalidEnvelope }
        return UInt32(unsignedLE(payload.prefix(4)))
    }
    public struct Advertisement: Equatable {
        public let deviceID: UInt32
        public let counter: UInt32
        public let nonce: Data
        public let sleepSeconds: UInt8?
        public let battery: UInt8?
        public let status: UInt8?
        public let firmware: UInt8?
        public let hardware: UInt8?
    }
    /// Payload excludes the two company-ID bytes. The optional state MAC is checked separately.
    public static func verifyAdvertisement(_ bytes: Data, ownerSecret: Data) throws -> Advertisement {
        let payload = Data(bytes)
        guard ownerSecret.count == 32, [16,17,21,24].contains(payload.count) else { throw GuestCrypto.Failure.invalidEnvelope }
        let message = payload.count >= 21 ? Data(payload.prefix(8)) + Data(payload[16..<21]) : Data(payload.prefix(8))
        guard equal(Data(hmac(ownerSecret, message).prefix(8)), Data(payload[8..<16])) else { throw GuestCrypto.Failure.invalidKey }
        var opts: [UInt8]?
        if payload.count >= 21 {
            let stream = hmac(ownerSecret, Data("ks".utf8) + payload.prefix(8))
            opts = (0..<4).map { payload[17 + $0] ^ stream[$0] }
        }
        return Advertisement(deviceID: UInt32(unsignedLE(payload.prefix(4))), counter: UInt32(unsignedLE(payload[4..<8])),
            nonce: Data(payload[8..<16]), sleepSeconds: payload.count >= 17 ? payload[16] : nil,
            battery: opts?[0], status: opts?[1], firmware: opts?[2], hardware: opts?[3])
    }
    public static func state(_ bytes: Data, stateKey key: Data) throws -> UInt8? {
        let payload = Data(bytes), stateKey = Data(key)
        guard stateKey.count == 16 else { throw GuestCrypto.Failure.invalidKey }
        guard payload.count == 24 else { return nil }
        let input = Data(payload[4..<8]) + Data([payload[21]])
        guard equal(Data(hmac(stateKey, input).prefix(2)), Data(payload[22..<24])) else { throw GuestCrypto.Failure.invalidKey }
        return payload[21] ^ stateKey[Int(payload[4] & 15)]
    }
    static func littleEndian(_ value: UInt64, count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func unsignedLE<T: DataProtocol>(_ data: T) -> UInt64 { data.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) } }
    static func hmac(_ key: Data, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
    private static func hkdf(secret: Data, salt: Data = Data(), info: Data, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: info, outputByteCount: count).withUnsafeBytes { Data($0) }
    }
    private static func equal(_ a: Data, _ b: Data) -> Bool { a.count == b.count && zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0 }
}
