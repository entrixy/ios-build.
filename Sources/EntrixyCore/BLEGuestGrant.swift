import Foundation
import CoreFoundation

public struct BLEGuestGrant: Codable, Equatable {
    public let objectID: Int
    public let deviceID: UInt32
    public let token: Data
    public let ownerSignature: Data
    public let guestKey: Data
    public let stateKey: Data?
    public let validUntil: UInt32
    public var guestID: UInt16 { UInt16(BLECrypto.unsignedLE(token.prefix(2))) }
    public init(row: [String: Any]) throws {
        objectID = try OwnerObject.replyID(row["id"])
        guard let number = row["did"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int64(number.stringValue), number == NSNumber(value: value), (-2_147_483_648...4_294_967_295).contains(value),
              let encodedToken = row["token"] as? String, let token = Data(base64Encoded: encodedToken), token.count == 7,
              let sig = row["sig"] as? String, let signature = Data(base64Encoded: sig), signature.count == 16,
              let gkey = row["gkey"] as? String, let key = Data(base64Encoded: gkey), key.count == 32 else { throw GuestCrypto.Failure.invalidEnvelope }
        deviceID = value < 0 ? UInt32(bitPattern: Int32(value)) : UInt32(value)
        self.token = token; ownerSignature = signature; guestKey = key
        validUntil = UInt32(BLECrypto.unsignedLE(token[2..<6]))
        if let raw = row["valid_until"], !(raw is NSNull) {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n == NSNumber(value: validUntil) else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        if let encoded = row["kstate"] as? String {
            guard let key = Data(base64Encoded: encoded), key.count == 16 else { throw GuestCrypto.Failure.invalidKey }
            stateKey = key
        } else { stateKey = nil }
        try validate()
    }
    public func validate() throws {
        guard objectID > 0, token.count == 7, token.last == 1, ownerSignature.count == 16, guestKey.count == 32,
              guestID != 0, validUntil == UInt32(BLECrypto.unsignedLE(token.dropFirst(2).prefix(4))),
              stateKey == nil || stateKey!.count == 16 else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public func isValid(at epoch: UInt64) -> Bool { epoch <= UInt64(validUntil) }
}
