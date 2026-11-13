import XCTest
@testable import EntrixyCore

final class BLELifecycleTests: XCTestCase {
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server: "https://fixture.invalid")
        for (number, did) in [(7, UInt32(123)), (8, UInt32(124))] {
            let peer = BLECrypto.makePair()
            var pair = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: did, label: "Дверь \(number)")
            try pair.markSent()
            let secret = try pair.secret(masterKey: owner.masterKey)
            let head = BLECrypto.littleEndian(UInt64(did), count: 4) + Data([1,0,0,0])
            try pair.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: owner.masterKey)
            var object = try OwnerObject(pairing: pair, masterKey: owner.masterKey)
            object.numberID = number; object.pending = nil; object.available = true
            owner.objects = (owner.objects ?? []) + [object]
        }
        var key = try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7,8], welcome: "", nativeOnly: false, confirmation: true)
        key.keyID = 17; key.pending = nil; key.state = .active; key.effectiveNumberIDs = [7,8]
        owner.issuedKeys = [key]
        return owner
    }
    func testScopedRestorationNeverAllowsOtherRevokedObjectsAndWaitsForFreshAck() throws {
        var owner = try owner()
        let key = owner.issuedKeys![0]
        try owner.queueBLEDecision(keyID: key.id, revoked: true, epoch: 100)
        XCTAssertEqual(owner.bleRevocations?.count, 2)
        owner.scheduleBLERestoration(keyID: key.id, objectIDs: [8])
        owner.issuedKeys![0].pending = .keyEdit
        try owner.reconcileBLERestoration()
        XCTAssertTrue(owner.bleRevocations!.allSatisfy(\.revoked))
        XCTAssertEqual(owner.bleRestorePending, [key.id])
        owner.issuedKeys![0].pending = nil
        try owner.reconcileBLERestoration()
        XCTAssertEqual(owner.bleRevocations?.first(where: { $0.deviceID == 123 })?.revoked, true)
        XCTAssertEqual(owner.bleRevocations?.first(where: { $0.deviceID == 124 })?.revoked, false)
        XCTAssertEqual(owner.bleRestorePending, [])
        let versions = owner.bleRevocations!.map(\.version)
        try owner.reconcileBLERestoration()
        XCTAssertEqual(owner.bleRevocations!.map(\.version), versions)
        try owner.validate()
    }
    func testDeletionRetainsWrappedSecretButRemovesActuationObject() throws {
        var owner = try owner()
        let object = owner.objects![0]
        owner.objects![0].pending = .delete; owner.objects![0].sent = true
        let snapshot = try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [["id": 8, "type": "ble", "data_cipher": owner.objects![1].cipher]], "keys": []]))
        try owner.reconcileObjects(snapshot)
        XCTAssertEqual(owner.objects?.count, 1)
        XCTAssertEqual(owner.bleArchivedObjects?.first?.id, object.id)
        XCTAssertEqual(owner.bleArchivedObjects?.first?.wrappedBLESecret, object.wrappedBLESecret)
        XCTAssertEqual(owner.bleArchivedObjects?.first?.available, false)
        XCTAssertNil(owner.bleArchivedObjects?.first?.pending)
        try owner.validate()
    }
    func testRenewalKeepsIdentityScopePolicyAndDoesNotAllowPausedKey() throws {
        var owner = try owner()
        let key = owner.issuedKeys![0]
        let link = try key.link(server: owner.server, masterKey: owner.masterKey)
        let pair = try key.secrets(masterKey: owner.masterKey)
        try owner.issuedKeys![0].renewBLE(owner: owner)
        let updated = owner.issuedKeys![0]
        XCTAssertEqual(updated.pending, .keyEdit); XCTAssertFalse(updated.sent)
        XCTAssertEqual(updated.guestID, key.guestID); XCTAssertEqual(updated.numberIDs, key.numberIDs)
        XCTAssertEqual(try updated.secrets(masterKey: owner.masterKey).userKey, pair.userKey)
        XCTAssertEqual(try updated.secrets(masterKey: owner.masterKey).bundleKey, pair.bundleKey)
        XCTAssertEqual(try updated.bundle(masterKey: owner.masterKey)["templates"] as? [String: [String: Bool]], [:])
        var accepted = updated; accepted.pending = nil
        XCTAssertEqual(try accepted.link(server: owner.server, masterKey: owner.masterKey), link)
        accepted.state = .paused
        XCTAssertThrowsError(try accepted.renewBLE(owner: owner))
    }
}
