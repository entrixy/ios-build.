import XCTest
@testable import EntrixyCore

final class OwnerObjectRulesTests: XCTestCase {
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server: "owner.invalid")
        var a = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "webhook", url: "https://relay.invalid/open", secret: "owner-secret")
        a.numberID = 7; a.revision = 1; a.pending = nil; a.available = true
        var local = OwnerObjectLocalConfiguration(); local.camera.enabled = true
        local.camera.url = "https://camera.invalid/image.jpg"; local.camera.authType = "bearer"; local.camera.authValue = "camera-secret"
        a.localConfiguration = local
        var b = a; b.numberID = 8
        owner.objects = [a]
        return owner
    }
    private func key(_ owner: OwnerAccount) throws -> OwnerIssuedKey {
        var k = try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7], welcome: "Добро пожаловать", nativeOnly: false, confirmation: false)
        k.keyID = 100; k.pending = nil; k.state = .active
        return k
    }
    func testEditingOneGuestKeepsItsSigningIdentityAndOtherGuestUnchanged() throws {
        let owner = try owner(); var first = try key(owner); let second = try key(owner)
        let secrets = first.wrappedSecrets, did = first.guestID, secondCipher = second.bundleCipher
        var template = AutomationTemplate(); template.geoEnabled = true; template.geoLat = 55; template.geoLon = 37
        template.geoLevel = .force; template.radiusM = 40
        try first.setObjectRules(owner: owner, numberID: 7, template: template, allowStream: false)
        XCTAssertEqual(first.wrappedSecrets, secrets); XCTAssertEqual(first.guestID, did)
        XCTAssertEqual(second.bundleCipher, secondCipher)
        XCTAssertEqual(first.pending, .keyEdit); XCTAssertNil(first.requestedAccess)
        let contents = try first.bundle(masterKey: owner.masterKey)
        XCTAssertEqual((contents["templates"] as? [String: [String: Any]])?["7"]?["geo_l"] as? String, "force")
        XCTAssertEqual(contents["streams"] as? [Int], [])
        XCTAssertEqual((contents["cams"] as? [String: Any])?.count, 0)
    }
    func testCameraCredentialsArePerGuestAndDoNotEnterObjectCipher() throws {
        let owner = try owner(); let key = try key(owner)
        let contents = try key.bundle(masterKey: owner.masterKey)
        XCTAssertEqual((contents["cams"] as? [String: [String: Any]])?["7"]?["val"] as? String, "camera-secret")
        XCTAssertNil(try owner.objects![0].metadata(masterKey: owner.masterKey)["snap_val"])
        let child = try OwnerIssuedKey.makeBundle(owner: owner, numberIDs: [7], guestID: 42, welcome: "", confirmation: nil,
            existing: ["streams": [Int](), "cams": [String: Any]()], inheritRestrictions: true)
        let inherited = try XCTUnwrap(JSONSerialization.jsonObject(with: child) as? [String: Any])
        XCTAssertEqual((inherited["cams"] as? [String: Any])?.count, 0)
    }
    func testObjectGeoIsResolvedWhenRebuildingWithoutChangingOtherRules() throws {
        var owner = try owner(); var own = AutomationTemplate(); own.geoLat = 55; own.geoLon = 37; own.radiusM = 50
        owner.objects![0].localPolicy = try own.data()
        var issued = try key(owner), template = AutomationTemplate()
        template.geoFromOwner = true; template.geoEnabled = true; template.authEnabled = true; template.authMode = "pin"
        try issued.setObjectRules(owner: owner, numberID: 7, template: template, allowStream: true)
        let contents = try issued.bundle(masterKey: owner.masterKey)
        let json = try XCTUnwrap((contents["templates"] as? [String: [String: Any]])?["7"])
        XCTAssertEqual(json["lat"] as? Double, 55); XCTAssertEqual(json["rad"] as? Int, 50)
        XCTAssertEqual(json["auth"] as? String, "pin"); XCTAssertEqual(json["geo_own"] as? Bool, false)
        XCTAssertEqual(try issued.objectTemplate(numberID: 7, owner: owner).geoFromOwner, true)
    }
    func testInvalidGuestTemplateDoesNotReserveOrReplaceBundle() throws {
        let owner = try owner(); var issued = try key(owner), invalid = AutomationTemplate()
        let previous = issued; invalid.bleRadiusM = 100
        XCTAssertThrowsError(try issued.setObjectRules(owner: owner, numberID: 7, template: invalid, allowStream: false))
        XCTAssertEqual(issued, previous)
    }
    func testLocalRuleEditsCannotReplaceAnAlreadySentBundle() throws {
        var owner = try owner(); var issued = try key(owner)
        var first = AutomationTemplate(); first.timeEnabled = true
        first.timeEntries = [.init(weekdays: [2], fromMin: 480, toMin: 600)]
        try issued.setObjectRules(owner: owner, numberID: 7, template: first, allowStream: true)
        issued.sent = true
        let request = try issued.request(masterKey: owner.masterKey)
        var newer = first; newer.timeEntries[0].fromMin = 540
        try issued.configureObjectSettings(numberID: 7, template: newer, allowStream: false, masterKey: owner.masterKey)
        XCTAssertEqual(try issued.request(masterKey: owner.masterKey), request)
        XCTAssertTrue(issued.sent)
        XCTAssertEqual(try issued.objectTemplate(numberID: 7, owner: owner).timeEntries[0].fromMin, 540)
        owner.issuedKeys = [issued]; owner.queueObjectSettings(numberID: 7)
        let old = owner.bundleRefreshQueue
        owner.queueObjectSettings(numberID: 7)
        XCTAssertNotEqual(owner.bundleRefreshQueue, old)
        let restarted = try JSONDecoder().decode(OwnerAccount.self, from: JSONEncoder().encode(owner))
        XCTAssertEqual(restarted.bundleRefreshQueue, owner.bundleRefreshQueue)
        XCTAssertEqual(restarted.issuedKeys?[0].bundleCipher, issued.bundleCipher)
    }

}
