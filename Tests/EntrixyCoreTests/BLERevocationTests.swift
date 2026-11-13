import XCTest
@testable import EntrixyCore

final class BLERevocationTests: XCTestCase {
    func testSignedDecisionWireAndControllerReceiptMeaning() throws {
        let secret = Data(repeating: 7, count: 32)
        var record = try BLERevocation(deviceID: 0xf1234567, guestID: 513, version: 100, revoked: true, ownerSecret: secret)
        XCTAssertEqual(record.frame, try BLECrypto.revoke(ownerSecret: secret, guestID: 513, version: 100, revoked: true))
        XCTAssertTrue(try record.verify(ownerSecret: secret))
        XCTAssertFalse(try record.verify(ownerSecret: Data(repeating: 8, count: 32)))
        let decoded = try BLERevocation(row: record.json)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(record.json["lock_did"] as? Int64, Int64(Int32(bitPattern: record.deviceID)))
        XCTAssertThrowsError(try record.receiveControllerResult(0))
        XCTAssertFalse(record.applied)
        try record.receiveControllerResult(0x41)
        XCTAssertFalse(record.applied)
        try record.receiveControllerResult(0x40)
        XCTAssertTrue(record.applied)
    }
    func testMergeDoesNotRollbackOrAcceptContradictorySameVersion() throws {
        let secret = Data(repeating: 7, count: 32)
        let old = try BLERevocation(deviceID: 123, guestID: 9, version: 100, revoked: true, ownerSecret: secret)
        let allowed = try BLERevocation(deviceID: 123, guestID: 9, version: 101, revoked: false, ownerSecret: secret)
        XCTAssertEqual(try BLERevocation.merge([old], into: [allowed], limit: 500), [allowed])
        XCTAssertEqual(try BLERevocation.merge([allowed], into: [old], limit: 500), [allowed])
        let forged = try BLERevocation(deviceID: 123, guestID: 9, version: 101, revoked: true, ownerSecret: secret)
        XCTAssertThrowsError(try BLERevocation.merge([forged], into: [allowed], limit: 500))
        var invalid = old.json; invalid["version"] = true
        XCTAssertThrowsError(try BLERevocation(row: invalid))
        let bytes = try JSONSerialization.data(withJSONObject: ["items": [old.json, old.json]])
        XCTAssertThrowsError(try BLERevocation.decode(bytes))
    }
    func testQueueIncreasesVersionAndRefusesAllowBeforeFreshActiveAuthority() throws {
        var owner = try OwnerAccount(server: "https://fixture.invalid")
        let peer = BLECrypto.makePair()
        var pair = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "Дверь")
        try pair.markSent()
        let secret = try pair.secret(masterKey: owner.masterKey)
        let head = Data([123,0,0,0,1,0,0,0])
        try pair.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: owner.masterKey)
        var object = try OwnerObject(pairing: pair, masterKey: owner.masterKey)
        object.numberID = 7; object.pending = nil; object.available = true; owner.objects = [object]
        var key = try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        key.keyID = 17; key.pending = nil; key.state = .active; owner.issuedKeys = [key]
        try owner.queueBLEDecision(keyID: key.id, revoked: true, epoch: 100)
        XCTAssertEqual(owner.bleRevocations?.first?.version, 100)
        owner.issuedKeys![0].state = .paused
        XCTAssertThrowsError(try owner.queueBLEDecision(keyID: key.id, revoked: false, epoch: 99))
        owner.issuedKeys![0].state = .active
        try owner.queueBLEDecision(keyID: key.id, revoked: false, epoch: 99)
        XCTAssertEqual(owner.bleRevocations?.first?.version, 101)
        XCTAssertEqual(owner.bleRevocations?.first?.revoked, false)
        XCTAssertTrue(try owner.bleRevocations![0].verify(ownerSecret: secret))
        let version = owner.bleRevocations![0].version
        try owner.queueBLEDecision(keyID: key.id, revoked: false, epoch: 99)
        XCTAssertEqual(owner.bleRevocations![0].version, version)
        try owner.queueBLEDecision(keyID: key.id, revoked: false, epoch: 99, forceVersion: true)
        XCTAssertEqual(owner.bleRevocations![0].version, version + 1)
        XCTAssertNil(owner.bleRevocations![0].controllerResult)
        try owner.validate()
    }
}
