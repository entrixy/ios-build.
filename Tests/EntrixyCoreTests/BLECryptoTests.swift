import Foundation
import XCTest
@testable import EntrixyCore

final class BLECryptoTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.module.url(forResource: "ble-v1", withExtension: "json", subdirectory: "Fixtures")!)) as! [String: Any]
    }
    private func bytes(_ f: [String: Any], _ key: String) -> Data { Data(base64Encoded: f[key] as! String)! }
    func testIndependentX25519PairAndAllFirmwarePacketVectors() throws {
        let f = try fixture(), secret = bytes(f,"owner_secret"), nonce = bytes(f,"nonce"), token = bytes(f,"guest_token"), sig = bytes(f,"owner_signature"), gkey = bytes(f,"guest_key")
        XCTAssertEqual(try BLECrypto.pairSecret(privateKey: bytes(f,"phone_private"), peerPublic: bytes(f,"esp_public")), secret)
        XCTAssertEqual(try BLECrypto.pairPacket(publicKey: bytes(f,"phone_public"), deviceID: 0x89abcdef), bytes(f,"pair_packet"))
        XCTAssertEqual(try BLECrypto.token(guestID: 513, validUntil: 1_800_086_400), token)
        XCTAssertEqual(try BLECrypto.guestKey(ownerSecret: secret, guestID: 513), gkey)
        XCTAssertEqual(try BLECrypto.ownerSignature(ownerSecret: secret, token: token), sig)
        XCTAssertEqual(try BLECrypto.stateKey(ownerSecret: secret), bytes(f,"state_key"))
        XCTAssertEqual(try BLECrypto.ownerFire(ownerSecret: secret, nonce: nonce), bytes(f,"owner_fire"))
        XCTAssertEqual(try BLECrypto.guestFire(token: token, ownerSignature: sig, guestKey: gkey, nonce: nonce), bytes(f,"guest_fire"))
        XCTAssertEqual(try BLECrypto.ownerTime(ownerSecret: secret, epochMilliseconds: 1_800_000_000_123, nonce: nonce), bytes(f,"owner_time"))
        XCTAssertEqual(try BLECrypto.guestTime(token: token, ownerSignature: sig, guestKey: gkey, epochMilliseconds: 1_800_000_000_123, nonce: nonce), bytes(f,"guest_time"))
        XCTAssertEqual(try BLECrypto.revoke(ownerSecret: secret, guestID: 513, version: 1_800_000_001, revoked: true), bytes(f,"revoke"))
    }
    func testAdvertiseVersionsOptionalTelemetryAndSeparateStateMAC() throws {
        let f = try fixture(), secret = bytes(f,"owner_secret")
        for name in ["adv_v1", "adv_v2", "adv_v3", "adv_state"] {
            let payload = bytes(f,name), decoded = try BLECrypto.verifyAdvertisement(payload, ownerSecret: secret)
            XCTAssertEqual(decoded.deviceID, 0x89abcdef)
            XCTAssertEqual(decoded.counter, 0x10203040)
            XCTAssertEqual(decoded.nonce, Data(payload[8..<16]))
            if payload.count >= 21 { XCTAssertEqual(decoded.battery, 87); XCTAssertEqual(decoded.status, 0x21); XCTAssertEqual(decoded.firmware, 0xa9); XCTAssertEqual(decoded.hardware, 3) }
        }
        let payload = bytes(f,"adv_state"), key = bytes(f,"state_key")
        XCTAssertEqual(try BLECrypto.state(payload, stateKey: key), 1)
        XCTAssertNil(try BLECrypto.state(bytes(f,"adv_v3"), stateKey: key))
        var corrupt = payload; corrupt[23] ^= 1
        XCTAssertThrowsError(try BLECrypto.state(corrupt, stateKey: key))
        corrupt = payload; corrupt[17] ^= 1
        XCTAssertThrowsError(try BLECrypto.verifyAdvertisement(corrupt, ownerSecret: secret))
        XCTAssertThrowsError(try BLECrypto.verifyAdvertisement(payload, ownerSecret: Data(repeating: 0, count: 32)))
    }
    func testInvalidLengthsAndLowOrderPairPointCannotProduceCredentials() throws {
        let f = try fixture(), secret = bytes(f,"owner_secret")
        XCTAssertThrowsError(try BLECrypto.pairSecret(privateKey: bytes(f,"phone_private"), peerPublic: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try BLECrypto.pairPacket(publicKey: Data(count: 31), deviceID: 7))
        XCTAssertThrowsError(try BLECrypto.ownerFire(ownerSecret: secret, nonce: Data(count: 7)))
        XCTAssertThrowsError(try BLECrypto.guestKey(ownerSecret: secret, guestID: 0))
        for count in [0,15,18,20,22,23,25] { XCTAssertThrowsError(try BLECrypto.verifyAdvertisement(Data(count: count), ownerSecret: secret)) }
        let a = BLECrypto.makePair(), b = BLECrypto.makePair()
        XCTAssertEqual(try BLECrypto.pairSecret(privateKey: a.privateKey, peerPublic: b.publicKey), try BLECrypto.pairSecret(privateKey: b.privateKey, peerPublic: a.publicKey))
    }
}
