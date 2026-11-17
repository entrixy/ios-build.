import XCTest
@testable import EntrixyCore

final class OwnerKeyConfigurationTests: XCTestCase {
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server: "owner.invalid")
        let peer = BLECrypto.makePair()
        var pairing = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "Дверь")
        try pairing.markSent()
        let secret = try pairing.secret(masterKey: owner.masterKey), head = Data([123,0,0,0,1,0,0,0])
        try pairing.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: owner.masterKey)
        var ble = try OwnerObject(pairing: pairing, masterKey: owner.masterKey)
        ble.numberID = 7; ble.pending = nil; ble.available = true
        var call = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "call", phone: "+15550000001")
        call.numberID = 8; call.pending = nil; call.available = true
        owner.objects = [ble,call]; return owner
    }
    func testPerObjectNativeRestrictionAndDraftTemplatesEnterTheFirstRequest() throws {
        let owner = try owner(); var settings = OwnerKeyConfiguration()
        var template = AutomationTemplate(); template.authEnabled = true; template.authMode = "pin"
        settings.automation["7"] = try template.data(); settings.bleLifetimes["7"] = 3600
        let access = try KeyObjectAccess(nativeOnly: true, depth: 2, pool: 8)
        let key = try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7], welcome: "", nativeOnly: true, confirmation: false, access: [7:access], settings: settings)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:key.request(masterKey:owner.masterKey)) as? [String:Any])
        XCTAssertEqual(try KeyObjectAccess.decode(body["objects"])?["7"],access)
        XCTAssertEqual(body["native_only"] as? Bool,true)
        let bundle = try key.bundle(masterKey:owner.masterKey)
        let row = try XCTUnwrap((bundle["ble"] as? [[String:Any]])?.first)
        let grant = try BLEGuestGrant(row:row)
        XCTAssertLessThanOrEqual(abs(Double(grant.validUntil)-Date().timeIntervalSince1970-3600),2)
        XCTAssertEqual((row["tpl"] as? [String:Any])?["auth"] as? String,"pin")
        XCTAssertFalse((row["tpl"] as? [String:Any])?["confirm_on"] as? Bool ?? false)
    }
    func testChangingTTLDoesNotReplaceExistingBundleAndRenewUsesNewLifetime() throws {
        let owner = try owner()
        var key = try OwnerIssuedKey(owner:owner,label:"Гость",numberIDs:[7],welcome:"",nativeOnly:false,confirmation:false)
        key.keyID = 10; key.pending = nil; key.state = .active
        let previous = key.bundleCipher, identity = key.wrappedSecrets
        try key.configureLifetime(numberID:7,seconds:604800)
        XCTAssertEqual(key.bundleCipher,previous); XCTAssertNil(key.pending)
        try key.renewBLE(owner:owner)
        let row = try XCTUnwrap((key.bundle(masterKey:owner.masterKey)["ble"] as? [[String:Any]])?.first)
        let grant = try BLEGuestGrant(row:row)
        XCTAssertLessThanOrEqual(abs(Double(grant.validUntil)-Date().timeIntervalSince1970-604800),2)
        XCTAssertEqual(key.wrappedSecrets,identity)
        XCTAssertThrowsError(try key.configureLifetime(numberID:99,seconds:3600))
        XCTAssertThrowsError(try key.configureLifetime(numberID:7,seconds:1800))
    }
    func testOwnerCallPreferenceStaysPrivateAcrossRestart() throws {
        var owner = try owner(); var config = OwnerKeyConfiguration(), preference = OwnerCallPreference()
        preference.reaction = "off"; config.calls["8"] = preference
        var key = try OwnerIssuedKey(owner:owner,label:"Гость",numberIDs:[8],welcome:"",nativeOnly:false,confirmation:false,settings:config)
        key.keyID = 10; key.pending = nil; key.state = .active; owner.issuedKeys = [key]
        XCTAssertEqual(owner.callPreference(guestID:key.id,numberID:8)?.reaction,"off")
        XCTAssertNil(try key.bundle(masterKey:owner.masterKey)["call_preferences"])
        let before = key.bundleCipher
        preference.reaction = "notify"; try key.configureCall(numberID:8,preference:preference)
        XCTAssertNil(key.pending); XCTAssertEqual(key.bundleCipher,before)
        try key.validate(masterKey:owner.masterKey)
        let restarted = try JSONDecoder().decode(OwnerIssuedKey.self,from:JSONEncoder().encode(key))
        XCTAssertEqual(restarted.callPreferences?["8"],preference)
    }
    func testInvalidDraftConfigurationCannotBeAppliedPartially() throws {
        let owner = try owner(); var configuration = OwnerKeyConfiguration()
        configuration.automation["99"] = try AutomationTemplate().data()
        XCTAssertThrowsError(try OwnerIssuedKey(owner:owner,label:"Гость",numberIDs:[7],welcome:"",nativeOnly:false,confirmation:false,settings:configuration))
    }
}
