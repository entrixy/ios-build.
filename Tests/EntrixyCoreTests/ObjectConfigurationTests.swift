import XCTest
@testable import EntrixyCore

final class ObjectConfigurationTests: XCTestCase {
    private let master = Data(repeating: 61, count: 32)
    private func object(_ kind: String = "webhook") throws -> OwnerObject {
        var object = try OwnerObject(masterKey: master, label: "Ворота", kind: kind,
            phone: "+15550000001", url: "https://relay.invalid/open", secret: "owner-secret")
        object.numberID = 7; object.pending = nil; object.available = true; object.revision = 123
        return object
    }
    func testPhoneModeKeepsCredentialsPrivateAndRoutesOnlyTheMode() throws {
        var object = try object()
        var draft = try OwnerObjectEdit(object: object, masterKey: master)
        draft.webhookMode = "phone"; draft.webhookURL = "http://192.168.1.2/open"
        draft.webhookSecret = "local-secret"; draft.webhookToggle = true
        try object.updateConfiguration(draft, masterKey: master)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: object.request()) as? [String: Any])
        XCTAssertEqual(request["webhook_mode"] as? String, "phone")
        XCTAssertNil(request["webhook_url"]); XCTAssertNil(request["webhook_secret"])
        XCTAssertEqual(object.routing["webhook_secret"], "local-secret")
        let metadata = try object.metadata(masterKey: master)
        XCTAssertEqual(metadata["wh_toggle"] as? Int, 1)
        XCTAssertNil(metadata["webhook_secret"]); XCTAssertNil(metadata["webhook_url"])
        try object.validate(masterKey: master)
    }
    func testServerModeUsesRevisionAndExactRoutingWithoutPlainPresentation() throws {
        var object = try object()
        let originalKey = object.wrappedKey
        var draft = try OwnerObjectEdit(object: object, masterKey: master)
        draft.label = "Калитка"; draft.webhookURL = "https://new.invalid/open"; draft.webhookSecret = "new-secret"
        try object.updateConfiguration(draft, masterKey: master)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: object.request()) as? [String: Any])
        XCTAssertEqual(request["data_cipher_ts_check"] as? Int, 123)
        XCTAssertEqual(request["webhook_url"] as? String, "https://new.invalid/open")
        XCTAssertEqual(request["webhook_secret"] as? String, "new-secret")
        XCTAssertNil(request["label"]); XCTAssertEqual(object.wrappedKey, originalKey)
    }
    func testPersistedUnsentEditRestoresPhoneCameraAndCipherTogether() throws {
        var object = try object("call"); let previous = object
        var draft = try OwnerObjectEdit(object: object, masterKey: master)
        draft.phone = "+1 (555) 000-0002"; draft.local.hangupSeconds = 8
        draft.local.camera.enabled = true; draft.local.camera.url = "https://camera.invalid/{key_id}.jpg"
        draft.local.camera.authType = "bearer"; draft.local.camera.authValue = "camera-secret"
        try object.updateConfiguration(draft, masterKey: master)
        object = try JSONDecoder().decode(OwnerObject.self, from: JSONEncoder().encode(object))
        XCTAssertEqual(object.localPhone, "+15550000002")
        XCTAssertNil(try object.metadata(masterKey: master)["snap_url"])
        XCTAssertFalse(String(decoding: try object.request(), as: UTF8.self).contains("camera-secret"))
        try object.cancelConfigurationUpdate(); XCTAssertEqual(object, previous)
    }
    func testStaleAndInvalidDraftsDoNotPartiallyMutateObject() throws {
        var object = try object(); let previous = object
        var invalid = try OwnerObjectEdit(object: object, masterKey: master)
        invalid.label = "Changed"; invalid.webhookURL = "javascript:alert(1)"
        XCTAssertThrowsError(try object.updateConfiguration(invalid, masterKey: master)); XCTAssertEqual(object, previous)
        let stale = try OwnerObjectEdit(object: object, masterKey: master)
        object.revision = 124; let concurrent = object
        XCTAssertThrowsError(try object.updateConfiguration(stale, masterKey: master)); XCTAssertEqual(object, concurrent)
    }
    func testTransmittedEditCannotBeCancelledAndCameraRejectsHeaderInjection() throws {
        var object = try object("call"); let draft = try OwnerObjectEdit(object: object, masterKey: master)
        try object.updateConfiguration(draft, masterKey: master); object.sent = true
        XCTAssertThrowsError(try object.cancelConfigurationUpdate())
        var camera = ObjectCameraConfiguration(); camera.enabled = true; camera.url = "https://camera.invalid/snap.jpg"
        camera.authType = "header"; camera.authHeader = "X-Test\r\nAuthorization"
        XCTAssertThrowsError(try camera.validate())
    }
}
