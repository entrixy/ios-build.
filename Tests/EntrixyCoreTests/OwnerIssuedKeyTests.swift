import Foundation
import XCTest
@testable import EntrixyCore

final class OwnerIssuedKeyTests: XCTestCase {
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "webhook", url: "https://actuator.invalid/open", secret: "owner-private-webhook-secret")
        object.numberID = 7; object.pending = nil; object.revision = 100
        owner.objects = [object]
        return owner
    }
    private func key(_ owner: OwnerAccount) throws -> OwnerIssuedKey {
        try OwnerIssuedKey(owner: owner, label: "Друг", numberIDs: [7], welcome: "Добро пожаловать", nativeOnly: false, confirmation: true)
    }
    private func snapshot(_ key: OwnerIssuedKey, owner: OwnerAccount, mode: String = "auto", enabled: Int = 1, id: Int = 17) throws -> OwnerSnapshot {
        let request = try JSONSerialization.jsonObject(with: keyRequest(key, owner: owner)) as! [String: Any]
        let object = owner.objects![0]
        return try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [["id": 7, "type": "webhook", "data_cipher": object.cipher, "data_cipher_revision": 100]],
            "keys": [["id": id, "enabled": enabled, "mode": mode, "sign_pub": request["sign_pub"]!, "number_ids": [7], "bundle_cipher": key.bundleCipher]]]))
    }
    private func keyRequest(_ key: OwnerIssuedKey, owner: OwnerAccount) throws -> Data {
        var copy = key; copy.pending = .keyCreate
        return try copy.request(masterKey: owner.masterKey)
    }

    func testIssuerBundleImportsWithExistingGuestProtocolAndNoOwnerOnlySecrets() throws {
        var owner = try owner(), key = try key(owner)
        let secrets = try key.secrets(masterKey: owner.masterKey)
        let request = try key.request(masterKey: owner.masterKey)
        let body = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        XCTAssertEqual(body["key_hash"] as? String, GuestCrypto.hash(Data(secrets.userKey.utf8)))
        XCTAssertNil(body["user_key"]); XCTAssertNil(body["label"]); XCTAssertNil(body["welcome"])
        XCTAssertFalse(String(decoding: request, as: UTF8.self).contains(secrets.userKey))
        let bundle = try GuestCrypto.decrypt(key: secrets.bundleKey, envelope: key.bundleCipher)
        let json = try JSONSerialization.jsonObject(with: bundle) as! [String: Any]
        XCTAssertEqual(json["welcome"] as? String, "Добро пожаловать")
        let objectKey = try GuestCrypto.decodeBase64URL((json["obj_keys"] as! [String: String])["7"]!)
        let metadata = try JSONSerialization.jsonObject(with: GuestCrypto.decrypt(key: objectKey, envelope: owner.objects![0].cipher)) as! [String: Any]
        XCTAssertNil(metadata["phone"]); XCTAssertNil(metadata["webhook_url"]); XCTAssertNil(metadata["webhook_secret"])
        XCTAssertThrowsError(try key.link(server: owner.server, masterKey: owner.masterKey))
        key.sent = true; owner.issuedKeys = [key]
        let snap = try snapshot(key, owner: owner)
        try owner.reconcileIssuedKeys(snap)
        key = owner.issuedKeys![0]
        XCTAssertEqual(key.keyID, 17); XCTAssertNil(key.pending)
        let invite = try GuestInvite.parse(key.link(server: owner.server, masterKey: owner.masterKey).absoluteString)
        XCTAssertEqual(invite.userKey, secrets.userKey); XCTAssertEqual(invite.bundleKey, secrets.bundleKey)
        let guestSnapshot = try JSONSerialization.data(withJSONObject: ["type": "guest_ok", "mode": "auto", "numbers": snap.rows])
        XCTAssertEqual(try GuestObjects.decode(bundle: bundle, snapshot: guestSnapshot).first?.label, "Ворота")
        let policy = try GuestActionPolicy.decode(bundle: bundle, snapshot: guestSnapshot, numberID: 7)
        XCTAssertTrue(policy.confirmation); XCTAssertTrue(policy.serverWebhook); XCTAssertNil(policy.blockedReason)
        try owner.validate()
    }

    func testLostCreateReplyAndKnownCreateIDBothReconcileWithoutNewKeyMaterial() throws {
        var owner = try owner(), issued = try key(owner)
        issued.sent = true
        owner.issuedKeys = [issued]
        let bytes = try JSONEncoder().encode(owner)
        owner = try JSONDecoder().decode(OwnerAccount.self, from: bytes)
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner))
        XCTAssertEqual(owner.issuedKeys![0].wrappedSecrets, issued.wrappedSecrets)
        XCTAssertEqual(owner.issuedKeys![0].state, .active)
        issued.keyID = 17; owner.issuedKeys = [issued]
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner))
        XCTAssertNil(owner.issuedKeys![0].pending)
    }

    func testPauseResumeAndRevocationNeverExposeLinkDuringUnknownState() throws {
        var owner = try owner(), issued = try key(owner)
        issued.sent = true; owner.issuedKeys = [issued]
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner))
        issued = owner.issuedKeys![0]
        issued.pending = .keyMode; issued.pendingMode = "off"; issued.sent = true; owner.issuedKeys = [issued]
        XCTAssertThrowsError(try issued.link(server: owner.server, masterKey: owner.masterKey))
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner, mode: "off"))
        XCTAssertEqual(owner.issuedKeys![0].state, .paused); XCTAssertNil(owner.issuedKeys![0].pending)
        issued = owner.issuedKeys![0]; issued.pending = .keyMode; issued.pendingMode = "auto"; issued.sent = true; owner.issuedKeys = [issued]
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner))
        XCTAssertEqual(owner.issuedKeys![0].state, .active)
        issued = owner.issuedKeys![0]; issued.pending = .keyRevoke; issued.sent = true; owner.issuedKeys = [issued]
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner, enabled: 0))
        XCTAssertEqual(owner.issuedKeys![0].state, .revoked)
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner))
        XCTAssertEqual(owner.issuedKeys![0].state, .revoked)
    }

    func testAbsentOrMismatchedCreationEvidenceDoesNotConfirmAccess() throws {
        var owner = try owner(), issued = try key(owner)
        issued.sent = true; owner.issuedKeys = [issued]
        try owner.reconcileIssuedKeys(OwnerSnapshot.decode(Data(#"{"numbers":[],"keys":[]}"#.utf8)))
        XCTAssertEqual(owner.issuedKeys![0].state, .draft); XCTAssertTrue(owner.issuedKeys![0].sent)
        issued.keyID = 99; owner.issuedKeys = [issued]
        XCTAssertThrowsError(try owner.reconcileIssuedKeys(snapshot(issued, owner: owner, id: 17)))
        XCTAssertEqual(owner.issuedKeys, [issued])
    }

    func testDeviceWithoutProvisioningLegacySecretsAndUnknownObjectAreRejected() throws {
        var owner = try owner()
        var device = try OwnerObject(masterKey: owner.masterKey, label: "Контроллер", kind: "device", claimCode: "TEST")
        device.numberID = 7; device.pending = nil; device.revision = 100; device.claimCode = nil
        owner.objects = [device]
        XCTAssertThrowsError(try key(owner))
        owner = try self.owner()
        let key = try GuestCrypto.decrypt(key: owner.masterKey, envelope: owner.objects![0].wrappedKey)
        owner.objects![0].cipher = try GuestCrypto.encrypt(key: key, plaintext: Data(#"{"label":"Legacy","webhook_secret":"never-share"}"#.utf8))
        XCTAssertThrowsError(try self.key(owner))
        XCTAssertThrowsError(try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [99], welcome: "", nativeOnly: false, confirmation: false))
        XCTAssertThrowsError(try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7], welcome: "", nativeOnly: true, confirmation: false))
    }

    func testIndependentAndroidSocketGrantAndProofVector() throws {
        let url = Bundle.module.url(forResource: "socket-owner-grant", withExtension: "json", subdirectory: "Fixtures")!
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let secret = Data(base64Encoded: fixture["ownerSecret"] as! String)!
        let grant = try OwnerIssuedKey.socketGrant(ownerSecret: secret, guestID: 513)
        for name in ["token", "sig", "gkey"] { XCTAssertEqual(grant[name] as? String, fixture[name] as? String) }
        let credential = try SocketCredential(json: grant)
        var session = GuestActionSession()
        try session.begin(numberID: 7, action: .open, credential: credential, now: 1)
        let frame = try session.fire(challenge: ["number_id": 7, "command_id": "fixture", "nonce": Data(0..<16).base64EncodedString()], now: 2)
        let json = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        XCTAssertEqual(json["proof"] as? String, fixture["proof"] as? String)
    }

    func testGuestIdentifiersDoNotCollideWithPersistedOrRevokedKeys() throws {
        var owner = try owner()
        let first = try key(owner)
        var revoked = first; revoked.keyID = 17; revoked.state = .revoked; revoked.pending = nil
        owner.issuedKeys = [revoked]
        let second = try key(owner)
        XCTAssertNotEqual(first.guestID, second.guestID)
        XCTAssertNotEqual(first.wrappedSecrets, second.wrappedSecrets)
    }
    func testEditPreservesInvitationIdentityAndUntouchedEncryptedRestrictions() throws {
        var owner = try owner(), issued = try key(owner)
        issued.sent = true; owner.issuedKeys = [issued]
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner))
        issued = owner.issuedKeys![0]
        let oldLink = try issued.link(server: owner.server, masterKey: owner.masterKey)
        let oldSecrets = issued.wrappedSecrets, oldGuestID = issued.guestID
        var bundle = try issued.bundle(masterKey: owner.masterKey)
        bundle["future_root"] = ["keep": true]
        bundle["net_block"] = [["s": "private-network"]]
        bundle["templates"] = ["7": ["mode": "all", "geo_on": true, "wifi_on": true, "auth_on": true, "auth": "pin", "confirm_on": false]]
        issued.bundleCipher = try GuestCrypto.encrypt(key: issued.secrets(masterKey: owner.masterKey).bundleKey, plaintext: JSONSerialization.data(withJSONObject: bundle))
        try issued.edit(owner: owner, label: "Новое имя", numberIDs: [7], welcome: "Новое приветствие")
        XCTAssertEqual(issued.wrappedSecrets, oldSecrets); XCTAssertEqual(issued.guestID, oldGuestID)
        let rebuilt = try issued.bundle(masterKey: owner.masterKey)
        XCTAssertEqual((rebuilt["future_root"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual((rebuilt["net_block"] as? [[String: String]])?.first?["s"], "private-network")
        let template = (rebuilt["templates"] as! [String: [String: Any]])["7"]!
        XCTAssertEqual(template["auth"] as? String, "pin")
        XCTAssertEqual(template["wifi_on"] as? Bool, true)
        XCTAssertEqual(template["confirm_on"] as? Bool, false)
        let body = try JSONSerialization.jsonObject(with: issued.request(masterKey: owner.masterKey)) as! [String: Any]
        XCTAssertNil(body["objects"]); XCTAssertNil(body["label"]); XCTAssertNil(body["welcome"])
        XCTAssertEqual(body["id"] as? Int, 17)
        XCTAssertThrowsError(try issued.link(server: owner.server, masterKey: owner.masterKey))
        issued.sent = true; owner.issuedKeys = [issued]
        try owner.reconcileIssuedKeys(snapshot(issued, owner: owner))
        XCTAssertEqual(try owner.issuedKeys![0].link(server: owner.server, masterKey: owner.masterKey), oldLink)
    }

    func testNarrowingPrunesKeysTemplatesAndCamerasButKeepsUnconfirmedServerScope() throws {
        var owner = try owner()
        var second = try OwnerObject(masterKey: owner.masterKey, label: "Калитка", kind: "call", phone: "+79990000001")
        second.numberID = 8; second.pending = nil; second.revision = 100
        owner.objects!.append(second)
        var issued = try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7,8], welcome: "", nativeOnly: false, confirmation: true)
        issued.keyID = 17; issued.state = .active; issued.pending = nil; issued.effectiveNumberIDs = [7,8]
        var bundle = try issued.bundle(masterKey: owner.masterKey)
        bundle["streams"] = [7,8]
        bundle["cams"] = ["7": ["url": "https://camera-a.invalid"], "8": ["url": "https://camera-b.invalid"]]
        let pair = try issued.secrets(masterKey: owner.masterKey)
        issued.bundleCipher = try GuestCrypto.encrypt(key: pair.bundleKey, plaintext: JSONSerialization.data(withJSONObject: bundle))
        let oldCipher = issued.bundleCipher
        try issued.edit(owner: owner, label: "Гость", numberIDs: [8], welcome: "")
        let edited = try issued.bundle(masterKey: owner.masterKey)
        XCTAssertEqual(Set((edited["obj_keys"] as! [String: String]).keys), ["8"])
        XCTAssertEqual(Set((edited["templates"] as! [String: [String: Any]]).keys), ["8"])
        XCTAssertEqual(edited["streams"] as? [Int], [8])
        XCTAssertEqual(Set((edited["cams"] as! [String: Any]).keys), ["8"])
        issued.sent = true; owner.issuedKeys = [issued]
        try owner.validate() // Old effective scope is allowed only during the pending edit.
        let publicKey = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: pair.userKey).publicKey.rawRepresentation)
        func server(_ cipher: String, _ ids: [Int]) throws -> OwnerSnapshot {
            try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [], "keys": [["id":17,"enabled":1,"mode":"auto","sign_pub":publicKey,"number_ids":ids,"bundle_cipher":cipher]]]))
        }
        try owner.reconcileIssuedKeys(server(oldCipher, [7,8]))
        XCTAssertEqual(owner.issuedKeys![0].pending, .keyEdit)
        XCTAssertEqual(owner.issuedKeys![0].effectiveNumberIDs, [7,8])
        try owner.reconcileIssuedKeys(server(issued.bundleCipher, [8]))
        XCTAssertNil(owner.issuedKeys![0].pending)
        XCTAssertEqual(owner.issuedKeys![0].effectiveNumberIDs, [8])
        try owner.validate()
    }

    func testExplicitConfirmationChangeDoesNotDisableAuthentication() throws {
        let owner = try owner()
        var issued = try key(owner)
        issued.keyID = 17; issued.state = .active; issued.pending = nil
        var bundle = try issued.bundle(masterKey: owner.masterKey)
        bundle["templates"] = ["7": ["auth_on":true,"auth":"pin","confirm":true]]
        issued.bundleCipher = try GuestCrypto.encrypt(key: issued.secrets(masterKey: owner.masterKey).bundleKey, plaintext: JSONSerialization.data(withJSONObject: bundle))
        try issued.edit(owner: owner, label: "Гость", numberIDs: [7], welcome: "", confirmation: false)
        let template = (try issued.bundle(masterKey: owner.masterKey)["templates"] as! [String:[String:Any]])["7"]!
        XCTAssertEqual(template["auth_on"] as? Bool, true)
        XCTAssertEqual(template["auth"] as? String, "pin")
        XCTAssertEqual(template["confirm_on"] as? Bool, false)
        XCTAssertNil(template["confirm"])
    }

}
