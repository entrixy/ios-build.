import XCTest
@testable import EntrixyCore

final class AndroidKeyRecoveryTests: XCTestCase {
    private func fixture() throws -> (OwnerAccount, OwnerIssuedKey, [String: Any]) {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "webhook", url: "https://actuator.invalid/open", secret: "public-fixture")
        object.numberID = 7; object.pending = nil; object.available = true; owner.objects = [object]
        var original = try OwnerIssuedKey(owner: owner, label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        original.keyID = 17; original.pending = nil; original.state = .active
        let pair = try original.secrets(masterKey: owner.masterKey)
        let material = AndroidOwnerKeyMaterial(serverKeyID: 17, userKey: pair.userKey,
            wrappedBundleKey: try GuestCrypto.encrypt(key: owner.masterKey, plaintext: pair.bundleKey),
            guestID: original.guestID, label: original.label,
            signPublic: GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: pair.userKey).publicKey.rawRepresentation))
        owner.androidKeys = [material]
        let row: [String: Any] = ["id": 17, "enabled": 1, "mode": "auto", "number_ids": [7], "ble_ids": [Int](),
            "bundle_cipher": original.bundleCipher, "sign_pub": material.signPublic!,
            "objects": [try KeyObjectAccess(depth: 2, pool: 8).json(id: 7)]]
        return (owner, original, row)
    }
    private func snapshot(_ row: [String: Any]) throws -> OwnerSnapshot {
        try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [], "keys": [row]]))
    }
    func testRecoveryUsesOriginalSigningAndBundleKeysButRequiresPermissionReview() throws {
        var (owner, original, row) = try fixture()
        XCTAssertEqual(try owner.reconcileAndroidKeys(snapshot(row)), 1)
        XCTAssertTrue(owner.androidKeys?.isEmpty == true)
        try owner.reconcileIssuedKeys(snapshot(row))
        let restored = try XCTUnwrap(owner.issuedKeys?.first)
        XCTAssertEqual(restored.guestID, original.guestID)
        XCTAssertEqual(restored.bundleCipher, original.bundleCipher)
        XCTAssertEqual(try restored.secrets(masterKey: owner.masterKey).userKey, try original.secrets(masterKey: owner.masterKey).userKey)
        XCTAssertEqual(try restored.link(server: owner.server, masterKey: owner.masterKey), try original.link(server: owner.server, masterKey: owner.masterKey))
        XCTAssertEqual(restored.accessNeedsReview, true)
        XCTAssertEqual(restored.grantedAccess?["7"]?.depth, 0)
        XCTAssertEqual(restored.access?["7"]?.depth, 2)
        let cipher = restored.bundleCipher, id = restored.id
        XCTAssertEqual(try owner.reconcileAndroidKeys(snapshot(row)), 0)
        XCTAssertEqual(owner.issuedKeys?.first?.bundleCipher, cipher)
        XCTAssertEqual(owner.issuedKeys?.first?.id, id)
        try owner.validate()
    }
    func testForgedPublicKeyAndForeignExpandedScopeKeepOriginalMaterialWithoutReplacement() throws {
        for changed in 0..<2 {
            var (owner, _, row) = try fixture()
            let original = owner.androidKeys![0]
            if changed == 0 { row["sign_pub"] = GuestCrypto.base64URL(Data(repeating: 0, count: 32)) }
            else { row["number_ids"] = [7,8]; row["objects"] = [try KeyObjectAccess().json(id: 7), try KeyObjectAccess().json(id: 8)] }
            XCTAssertEqual(try owner.reconcileAndroidKeys(snapshot(row)), 0)
            XCTAssertTrue(owner.issuedKeys?.isEmpty == true)
            XCTAssertEqual(owner.androidKeys?.first, original)
            XCTAssertEqual(owner.androidKeyFailures?["17"], "verification_required")
        }
    }
    func testReservedPhysicalGuestIDsCannotBeReissuedWhileImportedMaterialWaits() throws {
        var (owner, _, _) = try fixture()
        owner.reservedGuestIDs = Array(1...65535)
        XCTAssertThrowsError(try OwnerIssuedKey(owner: owner, label: "Новый", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true))
        XCTAssertEqual(owner.androidKeys?.count, 1)
    }
    func testCompanyRecoveryUsesLocallyRecordedAssociationAndPinnedKey() throws {
        var owner = try OwnerAccount(server:"owner.invalid")
        var object = try OwnerObject(masterKey:owner.masterKey,label:"Ворота",kind:"call",phone:"+79990001122")
        object.numberID = 7; object.pending = nil; object.available = true; owner.objects = [object]
        var profile = try KnownCompany(server:owner.server,json:["org_id":11,"name":"Компания","verified":false])
        profile.publicKey = Data(repeating:19,count:32)
        let original = try OwnerIssuedKey.forCompany(owner:owner,profile:profile,numberIDs:[7])
        let pair = try original.secrets(masterKey:owner.masterKey)
        var material = AndroidOwnerKeyMaterial(serverKeyID:17,userKey:pair.userKey,wrappedBundleKey:try GuestCrypto.encrypt(key:owner.masterKey,plaintext:pair.bundleKey),guestID:original.guestID,label:original.label,signPublic:GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey:pair.userKey).publicKey.rawRepresentation))
        material.companyID = 11; material.companyPublicKey = profile.publicKey
        owner.androidKeys = [material]
        var row: [String:Any] = ["id":17,"org_id":11,"enabled":1,"mode":"auto","number_ids":[7],"ble_ids":[Int](),"bundle_cipher":original.bundleCipher,"sign_pub":material.signPublic!,"objects":[try KeyObjectAccess(depth:0,pool:1).json(id:7)]]
        var mismatch = owner; row["org_id"] = 12
        XCTAssertEqual(try mismatch.reconcileAndroidKeys(snapshot(row)),0)
        XCTAssertEqual(mismatch.androidKeys?.first?.companyPublicKey,profile.publicKey)
        row["org_id"] = 11
        XCTAssertEqual(try owner.reconcileAndroidKeys(snapshot(row)),1)
        try owner.reconcileIssuedKeys(snapshot(row)); try owner.validate()
        let recovered = try XCTUnwrap(owner.issuedKeys?.first)
        XCTAssertEqual(recovered.company?.companyID,11); XCTAssertEqual(recovered.company?.publicKey,profile.publicKey)
        XCTAssertEqual(recovered.accessNeedsReview,false)
        XCTAssertThrowsError(try recovered.link(server:owner.server,masterKey:owner.masterKey))
        XCTAssertEqual(try owner.authorizedGuest(keyID:17,numberID:7)?.publicKey,profile.publicKey)
    }

}
