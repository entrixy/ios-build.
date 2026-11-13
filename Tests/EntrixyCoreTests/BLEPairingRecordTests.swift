import XCTest
@testable import EntrixyCore

final class BLEPairingRecordTests: XCTestCase {
    private let master = Data(repeating: 7, count: 32)
    func testPairingSurvivesLostWriteReplyAndCannotResend() throws {
        let peer = BLECrypto.makePair()
        var record = try BLEPairingRecord(masterKey: master, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 0xf1234567, label: " Ворота ")
        XCTAssertEqual(record.label, "Ворота")
        try record.validate(masterKey: master)
        XCTAssertThrowsError(try record.confirm(advertisement: Data(repeating: 0, count: 16), masterKey: master))
        let derived = try BLECrypto.pairSecret(privateKey: peer.privateKey, peerPublic: Data(record.packet.prefix(32)))
        XCTAssertEqual(try record.secret(masterKey: master), derived)
        try record.markSent()
        var restored = try JSONDecoder().decode(BLEPairingRecord.self, from: JSONEncoder().encode(record))
        XCTAssertThrowsError(try restored.markSent())
        let head = BLECrypto.littleEndian(UInt64(record.deviceID), count: 4) + BLECrypto.littleEndian(123, count: 4)
        let adv = head + BLECrypto.hmac(derived, head).prefix(8)
        try restored.confirm(advertisement: adv, masterKey: master)
        XCTAssertEqual(restored.phase, .confirmed)
        try restored.validate(masterKey: master)
        XCTAssertEqual(restored.wrappedSecret, record.wrappedSecret)
        XCTAssertThrowsError(try restored.markSent())
    }
    func testDiscoveryRequiresSecretAndExpectedDeviceID() throws {
        let peer = BLECrypto.makePair()
        var record = try BLEPairingRecord(masterKey: master, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "Дверь")
        try record.markSent()
        let head = BLECrypto.littleEndian(124, count: 4) + BLECrypto.littleEndian(1, count: 4)
        let secret = try record.secret(masterKey: master)
        XCTAssertThrowsError(try record.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: master))
        XCTAssertThrowsError(try record.confirm(advertisement: Data(repeating: 0, count: 16), masterKey: master))
        XCTAssertEqual(record.phase, .sent)
        XCTAssertThrowsError(try record.secret(masterKey: Data(repeating: 8, count: 32)))
        XCTAssertThrowsError(try BLEPairingRecord(masterKey: master, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 0, label: "Дверь"))
    }
    func testOwnerKeepsPairingSecretAndRejectsDuplicateDeviceIDs() throws {
        var owner = try OwnerAccount(server: "https://fixture.invalid")
        let peer = BLECrypto.makePair()
        let record = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "Дверь")
        owner.blePairings = [record]
        let restored = try JSONDecoder().decode(OwnerAccount.self, from: JSONEncoder().encode(owner))
        try restored.validate()
        XCTAssertEqual(restored.blePairings, [record])
        owner.blePairings?.append(record)
        XCTAssertThrowsError(try owner.validate())
    }
    func testConfirmedObjectKeepsOwnerSecretOutOfSharedMetadataAndServerRequest() throws {
        let peer = BLECrypto.makePair()
        var record = try BLEPairingRecord(masterKey: master, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "Дверь")
        XCTAssertThrowsError(try OwnerObject(pairing: record, masterKey: master))
        try record.markSent()
        let secret = try record.secret(masterKey: master)
        let head = BLECrypto.littleEndian(123, count: 4) + BLECrypto.littleEndian(1, count: 4)
        try record.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: master)
        let object = try OwnerObject(pairing: record, masterKey: master)
        try object.validate(masterKey: master)
        let shared = try object.metadata(masterKey: master)
        XCTAssertEqual(shared["label"] as? String, "Дверь")
        XCTAssertNil(shared["ble_secret"])
        let request = try JSONSerialization.jsonObject(with: object.request()) as! [String: Any]
        XCTAssertEqual(request["type"] as? String, "ble")
        XCTAssertNil(request["ble_secret"]); XCTAssertNil(request["wrappedBLESecret"])
        XCTAssertEqual(try GuestCrypto.decrypt(key: master, envelope: object.wrappedBLESecret!), secret)
        var owner = try OwnerAccount(server: "https://fixture.invalid")
        // Object and pairing must be wrapped by the correct account master key.
        owner.objects = [object]
        XCTAssertThrowsError(try owner.validate())
        // The wrong account cannot decrypt or issue this controller grant.
        XCTAssertThrowsError(try OwnerIssuedKey.makeBundle(owner: owner, numberIDs: [7], guestID: 1, welcome: "", confirmation: true))
    }

}
