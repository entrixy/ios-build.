import XCTest
@testable import EntrixyCore

final class BLEBundleTests: XCTestCase {
    private func fixture() throws -> (OwnerAccount, OwnerObject) {
        var owner = try OwnerAccount(server: "https://fixture.invalid")
        let peer = BLECrypto.makePair()
        var pair = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 0xf1234567, label: "Дверь")
        try pair.markSent()
        let secret = try pair.secret(masterKey: owner.masterKey)
        let head = BLECrypto.littleEndian(UInt64(pair.deviceID), count: 4) + BLECrypto.littleEndian(1, count: 4)
        try pair.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: owner.masterKey)
        var object = try OwnerObject(pairing: pair, masterKey: owner.masterKey)
        object.numberID = 7; object.pending = nil; object.available = true
        owner.objects = [object]
        return (owner, object)
    }
    func testGrantMatchesOwnerAndEditKeepsExpiryWhileExplicitRenewExtends() throws {
        let (owner, object) = try fixture()
        let row = try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: 9,
            template: ["confirm_on": true], epoch: 1000, ttl: 3600)
        let grant = try BLEGuestGrant(row: row)
        XCTAssertEqual(grant.validUntil, 4600); XCTAssertEqual(grant.guestID, 9)
        let secret = try GuestCrypto.decrypt(key: owner.masterKey, envelope: object.wrappedBLESecret!)
        XCTAssertEqual(grant.ownerSignature, try BLECrypto.ownerSignature(ownerSecret: secret, token: grant.token))
        let edit = try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: 9,
            template: ["confirm_on": false], existing: row, epoch: 2000, ttl: 3600)
        XCTAssertEqual(try BLEGuestGrant(row: edit), grant)
        let renewed = try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: 9,
            template: [:], existing: row, renew: true, epoch: 2000, ttl: 3600)
        XCTAssertEqual(try BLEGuestGrant(row: renewed).validUntil, 5600)
        let child = try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: 10,
            template: [:], existing: row, epoch: 3000)
        let childGrant = try BLEGuestGrant(row: child)
        XCTAssertEqual(childGrant.validUntil, grant.validUntil)
        XCTAssertNotEqual(childGrant.guestKey, grant.guestKey)
        XCTAssertEqual(childGrant.guestID, 10)
        let repeatChild = try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: 10,
            template: [:], existing: row, epoch: 4000)
        XCTAssertEqual(try BLEGuestGrant(row: repeatChild), childGrant)
        var wrong = row; wrong["sig"] = Data(repeating: 0, count: 16).base64EncodedString()
        XCTAssertThrowsError(try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: 9, template: [:], existing: wrong))
    }
    func testIssuedBLEBundleContainsOneCardNoOwnerSecretAndReconcilesSplitIDs() throws {
        var (owner, object) = try fixture()
        var key = try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        let secrets = try key.secrets(masterKey: owner.masterKey)
        let bytes = try GuestCrypto.decrypt(key: secrets.bundleKey, envelope: key.bundleCipher)
        let bundle = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertEqual(bundle["obj_ids"] as? [Int], [])
        XCTAssertEqual((bundle["obj_keys"] as? [String: String])?.count, 0)
        let rows = bundle["ble"] as! [[String: Any]]
        XCTAssertEqual(rows.count, 1); XCTAssertNil(rows[0]["ble_secret"])
        _ = try BLEGuestGrant(row: rows[0])
        let snapshot = try JSONSerialization.data(withJSONObject: ["numbers": [["id": 7, "type": "ble", "data_cipher": object.cipher]]])
        let objects = try GuestObjects.decode(bundle: bytes, snapshot: snapshot)
        XCTAssertEqual(objects.count, 1); XCTAssertEqual(objects[0].id, "b:7")
        key.sent = true; owner.issuedKeys = [key]
        let request = try JSONSerialization.jsonObject(with: key.request(masterKey: owner.masterKey)) as! [String: Any]
        let sync = try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [], "keys": [[
            "id": 17, "enabled": 1, "mode": "auto", "sign_pub": request["sign_pub"]!,
            "number_ids": [Int](), "ble_ids": [7], "objects": request["objects"]!, "bundle_cipher": key.bundleCipher]]]))
        try owner.reconcileIssuedKeys(sync)
        XCTAssertEqual(owner.issuedKeys?.first?.state, .active)
        XCTAssertNil(owner.issuedKeys?.first?.pending)
    }
    func testOfflinePolicyChecksExpiryAuthenticationAndCombinedRestrictions() throws {
        let (owner, object) = try fixture()
        var row = try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: 9,
            template: ["confirm_on": true, "auth_on": true, "auth": "either"], epoch: 1000, ttl: 3600)
        func bundle(_ row: [String: Any], net: [String] = []) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["ble": [row], "net_block": net])
        }
        let decoded = try GuestActionPolicy.decodeBLE(bundle: bundle(row), numberID: 7, epoch: 2000)
        XCTAssertEqual(decoded.policy.authentication, "either"); XCTAssertTrue(decoded.policy.confirmation)
        XCTAssertNil(decoded.policy.blockedReason)
        XCTAssertThrowsError(try GuestActionPolicy.decodeBLE(bundle: bundle(row), numberID: 7, epoch: 4601))
        XCTAssertNotNil(try GuestActionPolicy.decodeBLE(bundle: bundle(row, net: ["restricted"]), numberID: 7, epoch: 2000).policy.blockedReason)
        row["tpl"] = ["mode": "all", "geo_on": true, "ble_on": true]
        XCTAssertNotNil(try GuestActionPolicy.decodeBLE(bundle: bundle(row), numberID: 7, epoch: 2000).policy.blockedReason)
        row["tpl"] = ["auth_on": 1, "auth": "pin"]
        XCTAssertThrowsError(try GuestActionPolicy.decodeBLE(bundle: bundle(row), numberID: 7, epoch: 2000))
    }
}
