import Foundation
import XCTest
@testable import EntrixyCore

final class OwnerDelegatedKeyTests: XCTestCase {
    func testNativeOnlyDelegationIsAcceptedOnlyWhenItKeepsTheLocallyIssuedRestriction() throws {
        var owner = try owner(), root = try XCTUnwrap(owner.issuedKeys?.first)
        let native = try KeyObjectAccess(nativeOnly:true,depth:2,pool:8)
        root.grantedAccess = ["7":native]; root.access = ["7":native]; owner.issuedKeys = [root]
        let recipient = BundleKeySeal.makeRecipient()
        var child = try row(owner:owner,recipient:recipient)
        child["objects"] = [try KeyObjectAccess(nativeOnly:false,depth:1,pool:3).json(id:7)]
        XCTAssertEqual(try owner.reconcileDelegatedKeys(snapshot([child])),1)
        XCTAssertTrue((owner.delegatedKeys ?? []).isEmpty)
        child["objects"] = [try KeyObjectAccess(nativeOnly:true,depth:1,pool:3).json(id:7)]
        XCTAssertEqual(try owner.reconcileDelegatedKeys(snapshot([child])),0)
        XCTAssertEqual(owner.delegatedKeys?.first?.access["7"]?.nativeOnly,true)
    }
    private let childUser = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3"
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "webhook", url: "https://actuator.invalid/open", secret: "owner-only-secret")
        object.numberID = 7; object.pending = nil; object.revision = 100; object.available = true
        owner.objects = [object]
        var root = try OwnerIssuedKey(owner: owner, label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false,
            confirmation: true, access: [7: KeyObjectAccess(depth: 2, pool: 8)])
        root.keyID = 17; root.state = .active; root.pending = nil; root.access = root.grantedAccess
        root.requestedAccess = nil; root.effectiveNumberIDs = [7]
        owner.issuedKeys = [root]
        return owner
    }
    private func row(owner: OwnerAccount, childID: Int = 18, parentID: Int = 17, parentUser: String? = nil,
                     user: String? = nil, recipient: BundleKeySeal.Recipient, depth: Int = 1, pool: Int = 3) throws -> [String: Any] {
        let parent = try parentUser ?? owner.issuedKeys![0].secrets(masterKey: owner.masterKey).userKey
        let sp = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: user ?? childUser).publicKey.rawRepresentation)
        let vouch = try DelegationProof.vouch(userKey: parent, server: owner.server, childID: childID, signPublic: sp, guestPublic: recipient.publicKey)
        return ["id": childID, "parent_key_id": parentID, "enabled": 1, "mode": "auto", "sign_pub": sp,
            "guest_pub": recipient.publicKey, "vouch_sig": vouch, "number_ids": [7], "ble_ids": [Int](),
            "objects": [try KeyObjectAccess(depth: depth, pool: pool).json(id: 7)], "needs_bundle": 1]
    }
    private func snapshot(_ rows: [[String: Any]]) throws -> OwnerSnapshot {
        try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [], "keys": rows]))
    }
    private func confirmed(_ row: [String: Any], record: OwnerDelegatedKey) -> [String: Any] {
        var row = row; row["bundle_cipher"] = record.bundleCipher; row["key_cipher"] = record.keyCipher; row["needs_bundle"] = 0
        return row
    }
    func testBLEDescendantKeepsParentExpiryAndSubtreePauseRestoreUsesDifferentDIDs() throws {
        var owner = try owner()
        let peer = BLECrypto.makePair()
        var pair = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "BLE-ворота")
        try pair.markSent()
        let secret = try pair.secret(masterKey: owner.masterKey), head = Data([123,0,0,0,1,0,0,0])
        try pair.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: owner.masterKey)
        var object = try OwnerObject(pairing: pair, masterKey: owner.masterKey)
        object.numberID = 7; object.pending = nil; object.available = true; owner.objects = [object]
        var root = owner.issuedKeys![0]
        try root.edit(owner: owner, label: root.label, numberIDs: [7], welcome: "", confirmation: nil)
        root.pending = nil; owner.issuedKeys![0] = root
        let recipient = BundleKeySeal.makeRecipient()
        var child = try row(owner: owner, recipient: recipient)
        child["number_ids"] = [Int](); child["ble_ids"] = [7]
        try owner.reconcileDelegatedKeys(snapshot([child]))
        let record = try XCTUnwrap(owner.delegatedKeys?.first)
        let rootBLE = try root.bundle(masterKey: owner.masterKey)["ble"] as! [[String: Any]]
        let childBLE = try record.bundle(masterKey: owner.masterKey)["ble"] as! [[String: Any]]
        let rootGrant = try BLEGuestGrant(row: rootBLE[0]), childGrant = try BLEGuestGrant(row: childBLE[0])
        XCTAssertNotEqual(rootGrant.guestID, childGrant.guestID)
        XCTAssertEqual(rootGrant.validUntil, childGrant.validUntil)
        XCTAssertEqual(childGrant.ownerSignature, try BLECrypto.ownerSignature(ownerSecret: secret, token: childGrant.token))
        try owner.reconcileDelegatedKeys(snapshot([child]))
        XCTAssertEqual(owner.delegatedKeys?[0].bundleCipher, record.bundleCipher)
        child = confirmed(child, record: record)
        try owner.reconcileDelegatedKeys(snapshot([child]))
        XCTAssertEqual(owner.delegatedKeys?[0].state, .ready)
        owner.issuedKeys![0].state = .paused
        try owner.reconcileDelegatedKeys(snapshot([child]))
        XCTAssertEqual(owner.bleRevocations?.count, 2)
        XCTAssertTrue(owner.bleRevocations!.allSatisfy(\.revoked))
        let versions = owner.bleRevocations!.map(\.version).max()!
        owner.scheduleBLERestoration(keyID: root.id)
        try owner.reconcileBLERestoration()
        XCTAssertTrue(owner.bleRevocations!.allSatisfy(\.revoked))
        owner.issuedKeys![0].state = .active
        try owner.reconcileDelegatedKeys(snapshot([child]))
        try owner.reconcileBLERestoration()
        XCTAssertTrue(owner.bleRevocations!.allSatisfy { !$0.revoked && $0.version > versions })
        XCTAssertTrue(owner.bleRestorePending?.isEmpty == true)
        try owner.validate()
    }

    func testBundleIsPreparedDurablyAndOpensOnlyWithVouchedRecipient() throws {
        var owner = try owner()
        let recipient = BundleKeySeal.makeRecipient(), row = try row(owner: owner, recipient: recipient)
        XCTAssertEqual(try owner.reconcileDelegatedKeys(snapshot([row])), 0)
        let first = try XCTUnwrap(owner.delegatedKeys?.first)
        XCTAssertEqual(first.state, .awaiting)
        XCTAssertFalse(first.sent)
        XCTAssertNotEqual(first.guestID, owner.issuedKeys![0].guestID)
        let key = try BundleKeySeal.open(first.keyCipher, recipient: recipient)
        let bundle = try JSONSerialization.jsonObject(with: GuestCrypto.decrypt(key: key, envelope: first.bundleCipher)) as! [String: Any]
        XCTAssertEqual(bundle["obj_ids"] as? [Int], [7])
        XCTAssertEqual((bundle["templates"] as? [String: [String: Any]])?["7"]?["confirm_on"] as? Bool, true)
        XCTAssertFalse(String(decoding: try first.requestAfterMarkingSent(), as: UTF8.self).contains("owner-only-secret"))
        XCTAssertThrowsError(try BundleKeySeal.open(first.keyCipher, recipient: BundleKeySeal.makeRecipient()))
        owner.delegatedKeys![0].sent = true
        owner = try JSONDecoder().decode(OwnerAccount.self, from: JSONEncoder().encode(owner))
        try owner.validate()
        try owner.reconcileDelegatedKeys(snapshot([row]))
        XCTAssertEqual(owner.delegatedKeys![0].bundleCipher, first.bundleCipher)
        XCTAssertEqual(owner.delegatedKeys![0].keyCipher, first.keyCipher)
        XCTAssertEqual(owner.delegatedKeys![0].guestID, first.guestID)
        XCTAssertTrue(owner.delegatedKeys![0].sent)
        try owner.reconcileDelegatedKeys(snapshot([confirmed(row, record: first)]))
        XCTAssertEqual(owner.delegatedKeys![0].state, .ready)
        XCTAssertEqual(owner.delegatedKeys![0].confirmedNumberIDs, [7])
    }
    func testForgedVouchForeignObjectAndElevatedDepthPoolCannotReleaseKeys() throws {
        for mutation in 0..<5 {
            var owner = try owner(), row = try row(owner: owner, recipient: BundleKeySeal.makeRecipient())
            switch mutation {
            case 0: row["guest_pub"] = BundleKeySeal.makeRecipient().publicKey
            case 1: row["vouch_sig"] = Data(repeating: 0, count: 64).base64EncodedString()
            case 2: row["number_ids"] = [8]; row["objects"] = [try KeyObjectAccess().json(id: 8)]
            case 3: row["objects"] = [try KeyObjectAccess(depth: 2, pool: 3).json(id: 7)]
            default: row["objects"] = [try KeyObjectAccess(depth: 1, pool: 8).json(id: 7)]
            }
            XCTAssertEqual(try owner.reconcileDelegatedKeys(snapshot([row])), 1)
            XCTAssertTrue(owner.delegatedKeys?.isEmpty ?? true)
        }
        var owner = try owner()
        owner.issuedKeys![0].access = ["7": try KeyObjectAccess(depth: 5, pool: 50)]
        let elevated = try row(owner: owner, recipient: BundleKeySeal.makeRecipient(), depth: 3, pool: 20)
        try owner.reconcileDelegatedKeys(snapshot([elevated]))
        XCTAssertTrue(owner.delegatedKeys?.isEmpty ?? true, "A server snapshot cannot enlarge the owner's local grant")
    }
    func testDescendantWaitsForConfirmedParentAndWorksInReverseSnapshotOrder() throws {
        var owner = try owner()
        let recipient = BundleKeySeal.makeRecipient(), child = try row(owner: owner, recipient: recipient)
        let grand = try row(owner: owner, childID: 19, parentID: 18, parentUser: childUser,
            user: "QUJDREVGR0hJSktMTU5PUFFSUlNUVVZX", recipient: BundleKeySeal.makeRecipient(), depth: 0, pool: 1)
        try owner.reconcileDelegatedKeys(snapshot([grand, child]))
        XCTAssertEqual(owner.delegatedKeys?.count, 1)
        let record = owner.delegatedKeys![0]
        try owner.reconcileDelegatedKeys(snapshot([grand, confirmed(child, record: record)]))
        XCTAssertEqual(owner.delegatedKeys?.count, 2)
        XCTAssertEqual(owner.delegatedKeys?.first(where: { $0.keyID == 19 })?.state, .awaiting)
        owner.issuedKeys![0].state = .paused
        try owner.reconcileDelegatedKeys(snapshot([grand, confirmed(child, record: record)]))
        XCTAssertTrue(owner.delegatedKeys!.allSatisfy { $0.state == .unavailable })
    }
    func testGuestPressUsesVouchedPublicKeyAndRechecksTheEntireChain() throws {
        var owner = try owner()
        let recipient = BundleKeySeal.makeRecipient(), row = try row(owner: owner, recipient: recipient)
        try owner.reconcileDelegatedKeys(snapshot([row]))
        let record = owner.delegatedKeys![0]
        try owner.reconcileDelegatedKeys(snapshot([confirmed(row, record: record)]))
        let guest = try XCTUnwrap(owner.authorizedGuest(keyID: 18, numberID: 7))
        let data = try GuestPress.frame(userKey: childUser, host: owner.server, numberID: 7, wireAction: "")
        let press = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["press"] as! [String: Any]
        XCTAssertEqual(guest.id, record.id)
        XCTAssertFalse(try OwnerGuestPress.verify(press, publicKey: guest.publicKey, server: owner.server, numberID: 7).isEmpty)
        XCTAssertNil(try owner.authorizedGuest(keyID: 18, numberID: 8))
        owner.issuedKeys![0].pending = .keyMode
        XCTAssertNil(try owner.authorizedGuest(keyID: 18, numberID: 7))
        owner.issuedKeys![0].pending = nil
        owner.delegatedKeys![0].revocationPending = true
        XCTAssertNil(try owner.authorizedGuest(keyID: 18, numberID: 7))
    }
    func testRevokedRecordCannotBeResurrectedAndMissingRecipientBecomesUnavailable() throws {
        var owner = try owner()
        let row = try row(owner: owner, recipient: BundleKeySeal.makeRecipient())
        try owner.reconcileDelegatedKeys(snapshot([row]))
        owner.delegatedKeys![0].state = .revoked
        try owner.reconcileDelegatedKeys(snapshot([row]))
        XCTAssertEqual(owner.delegatedKeys![0].state, .revoked)
        try owner.reconcileDelegatedKeys(snapshot([]))
        XCTAssertEqual(owner.delegatedKeys![0].state, .revoked)
    }
}
private extension OwnerDelegatedKey {
    func requestAfterMarkingSent() throws -> Data { var copy = self; copy.sent = true; return try copy.request() }
}
