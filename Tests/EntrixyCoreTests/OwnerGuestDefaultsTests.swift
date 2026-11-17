import XCTest
@testable import EntrixyCore

final class OwnerGuestDefaultsTests: XCTestCase {
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server:"fixture.invalid")
        var pair = try BLEPairingRecord(masterKey:owner.masterKey,peripheralID:UUID(),peerPublic:BLECrypto.makePair().publicKey,deviceID:123,label:"Дверь")
        try pair.markSent()
        let head = Data([123,0,0,0,1,0,0,0]), secret = try pair.secret(masterKey:owner.masterKey)
        try pair.confirm(advertisement:head+BLECrypto.hmac(secret,head).prefix(8),masterKey:owner.masterKey)
        var object = try OwnerObject(pairing:pair,masterKey:owner.masterKey)
        object.numberID = 7; object.pending = nil; object.available = true; object.revision = 1
        owner.objects = [object]
        var key = try OwnerIssuedKey(owner:owner,label:"Гость",numberIDs:[7],welcome:"Привет",nativeOnly:false,confirmation:true,
            access:[7:KeyObjectAccess(depth:2,pool:6)])
        key.keyID = 17; key.state = .active; key.pending = nil
        key.access = ["7":try KeyObjectAccess(depth:1,pool:3)]; key.effectiveNumberIDs = [7]
        owner.issuedKeys = [key]; return owner
    }
    func testOwnerNameChangesOnlyEncryptedBundleAndKeepsIdentityExpiryAndPermissions() throws {
        var owner = try owner(), key = owner.issuedKeys![0]
        let original = key, ble = try key.bundle(masterKey:owner.masterKey)["ble"] as! [[String:Any]]
        owner.hostLabel = "PRIVATE_OWNER_NAME"
        try key.refreshObjectSettings(owner:owner)
        XCTAssertEqual(try key.bundle(masterKey:owner.masterKey)["host_label"] as? String,"PRIVATE_OWNER_NAME")
        XCTAssertFalse(String(decoding:try key.request(masterKey:owner.masterKey),as:UTF8.self).contains("PRIVATE_OWNER_NAME"))
        XCTAssertEqual(key.wrappedSecrets,original.wrappedSecrets); XCTAssertEqual(key.guestID,original.guestID)
        XCTAssertEqual(key.grantedAccess,original.grantedAccess)
        let after = try key.bundle(masterKey:owner.masterKey)["ble"] as! [[String:Any]]
        XCTAssertEqual(after[0]["token"] as? String,ble[0]["token"] as? String)
        var invalid = OwnerGuestDefaults(); invalid.ownerName = String(repeating:"x",count:41)
        XCTAssertThrowsError(try invalid.validate())
    }
    func testCloneHasNewKeysAndDIDFromItsFirstRequestAndRetainsLegacyForceRulesAndNetworkBan() throws {
        var owner = try owner(), source = owner.issuedKeys![0]
        var contents = try source.bundle(masterKey:owner.masterKey)
        contents["net_block"] = [["s":"private-network"]]
        var ble = contents["ble"] as! [[String:Any]]
        ble[0]["tpl"] = ["auth_on":true,"auth":"pin","auth_l":"force","confirm_on":true]
        contents["ble"] = ble
        let pair = try source.secrets(masterKey:owner.masterKey)
        source.bundleCipher = try GuestCrypto.encrypt(key:pair.bundleKey,plaintext:JSONSerialization.data(withJSONObject:contents))
        source.bleTokenLifetimes = ["7":3600]; owner.issuedKeys = [source]
        let clone = try source.cloned(owner:owner,label:"Гость (копия)")
        XCTAssertNotEqual(clone.id,source.id); XCTAssertNotEqual(clone.guestID,source.guestID)
        let copied = try clone.secrets(masterKey:owner.masterKey)
        XCTAssertNotEqual(copied.userKey,pair.userKey); XCTAssertNotEqual(copied.bundleKey,pair.bundleKey)
        XCTAssertEqual(clone.cloneSourceID,source.id); XCTAssertEqual(clone.pending,.keyCreate)
        let bundle = try clone.bundle(masterKey:owner.masterKey), rows = bundle["ble"] as! [[String:Any]]
        let grant = try BLEGuestGrant(row:rows[0]); XCTAssertEqual(grant.guestID,UInt16(clone.guestID))
        XCTAssertEqual((rows[0]["tpl"] as? [String:Any])?["auth"] as? String,"pin")
        XCTAssertEqual((bundle["net_block"] as? [[String:String]])?.first?["s"],"private-network")
        XCTAssertEqual(clone.grantedAccess?["7"],try KeyObjectAccess(depth:1,pool:3))
        XCTAssertFalse(String(decoding:try clone.request(masterKey:owner.masterKey),as:UTF8.self).contains(copied.userKey))
        try clone.validate(masterKey:owner.masterKey)
    }
    func testExplicitSharingPausedLinkNeverReactivatesItsAuthority() throws {
        var owner = try owner(); owner.issuedKeys![0].state = .paused
        let key = owner.issuedKeys![0]
        XCTAssertThrowsError(try key.link(server:owner.server,masterKey:owner.masterKey))
        let link = try key.link(server:owner.server,masterKey:owner.masterKey,allowPaused:true)
        XCTAssertEqual(try GuestInvite.parse(link.absoluteString).userKey,try key.secrets(masterKey:owner.masterKey).userKey)
        XCTAssertNil(try owner.authorizedGuest(localID:key.id,numberID:7))
        XCTAssertEqual(key.state,.paused); XCTAssertNil(key.pending)
    }
}
