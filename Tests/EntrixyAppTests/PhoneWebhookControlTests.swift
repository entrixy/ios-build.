import XCTest
import EntrixyCore
@testable import Entrixy

private final class WebhookStateStorage: StateStorage {
    var state: SavedState?
    var failing = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if failing { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}
private struct OfflineWebhookOwnerAPI: OwnerTransport {
    func register(server: String, accessCode: String) async throws -> OwnerCredentials { throw URLError(.notConnectedToInternet) }
    func sync(server: String, credentials: OwnerCredentials, fingerprint: String) async throws -> Data { throw URLError(.notConnectedToInternet) }
}
@MainActor private final class RecordingPhoneWebhook: PhoneWebhookSending {
    var calls: [(String, Data)] = []
    var beforeSend: (() -> Void)?
    var loseReply = false
    var holding = false
    var continuation: CheckedContinuation<PhoneWebhookReply, Error>?
    func send(url: String, body: Data) async throws -> PhoneWebhookReply {
        calls.append((url,body)); beforeSend?()
        if loseReply { throw URLError(.networkConnectionLost) }
        if holding { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try PhoneWebhook.reply(status: 200, data: Data(#"{"level":"success","message":"Ответ приёмника"}"#.utf8))
    }
}

@MainActor final class PhoneWebhookControlTests: XCTestCase {
    private func fixture(template: AutomationTemplate? = nil, toggles: Bool = false) throws -> (WebhookStateStorage, AppModel, OwnerObject, RecordingPhoneWebhook) {
        let storage = WebhookStateStorage()
        var owner = try OwnerAccount(server: "fixture.invalid")
        owner.credentials = try OwnerCredentials(deviceID: String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Webhook", kind: "webhook",
            url: "http://relay.invalid/open", secret: "owner-only", webhookMode: "phone", webhookToggle: toggles)
        object.localPolicy = try template?.data()
        object.numberID = 7; object.revision = 1; object.available = true; object.pending = nil
        owner.objects = [object]
        storage.state = SavedState(identity: Data(repeating: 24,count:32), guests: [], owners:[owner])
        let app = AppModel(storage: storage, ownerAPI: OfflineWebhookOwnerAPI())
        let sender = RecordingPhoneWebhook()
        app.ownerControl = OwnerControlModel(app: app, webhook: sender)
        app.ownerControl.resume()
        return (storage, app, object, sender)
    }
    private func routeProof(at date: Date = Date()) -> (AutomationTemplate,AutomationReadiness) {
        var template = AutomationTemplate()
        template.geoEnabled = true; template.geoMode = "route"; template.geoLat = 0; template.geoLon = 0
        template.corridors = [[AutomationGeoPoint(lat:160/111320,lon:0),AutomationGeoPoint(lat:0,lon:0)]]
        var runtime = AutomationRuntime(sessionStarted:date.timeIntervalSince1970-60)
        var proof: AutomationReadiness?
        for (i,distance) in [120.0,90,60,40,20].enumerated() {
            let time = date.addingTimeInterval(Double(i*10-40))
            runtime.receive(AutomationLocationFix(latitude:distance/111320,longitude:0,accuracyM:5,timestampMS:Int64(time.timeIntervalSince1970*1000)))
            proof = runtime.evaluate(key:"route",template:template,date:time)
        }
        return (template,proof!)
    }
    func testAutomaticRouteOpensOnlyOnceAndDoesNotChooseToggleForAnOpenOnlyTrigger() async throws {
        let (template,proof) = routeProof()
        XCTAssertTrue(proof.ready); XCTAssertTrue(proof.routeMatched)
        let (storage,app,object,sender) = try fixture(template:template,toggles:true)
        defer { app.suspend() }
        sender.loseReply = true
        sender.beforeSend = { XCTAssertEqual(storage.state?.journal?.count,1) }
        let entry = CatalogObject.owned(app.owners[0],object)
        await app.performAutomaticAction(entry,readiness:proof)
        await app.performAutomaticAction(entry,readiness:proof)
        XCTAssertEqual(sender.calls.count,1); XCTAssertEqual(app.journal.count,1)
        XCTAssertEqual(app.journal.first?.who,ProductText.string("journal_who_geo"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:sender.calls[0].1) as? [String:Any])
        XCTAssertEqual(body["action"] as? String,"open")
        XCTAssertTrue(app.automaticPermits.isEmpty)
    }
    func testAutomaticRouteCannotBypassChangedConfirmationOrExpiredEvidence() async throws {
        let (template,proof) = routeProof(at:Date().addingTimeInterval(-4))
        let (_,app,object,sender) = try fixture(template:template)
        defer { app.suspend() }
        await app.performAutomaticAction(.owned(app.owners[0],object),readiness:proof)
        XCTAssertTrue(sender.calls.isEmpty)
        var changed = template; changed.confirmEnabled = true
        let (_,gated,gatedObject,gatedSender) = try fixture(template:changed)
        defer { gated.suspend() }
        let (_,fresh) = routeProof()
        await gated.performAutomaticAction(.owned(gated.owners[0],gatedObject),readiness:fresh)
        XCTAssertTrue(gatedSender.calls.isEmpty); XCTAssertTrue(gated.journal.isEmpty)
    }
    func testAutomaticRouteStorageFailurePreventsPOSTAndDoesNotRetryTheSameEvidence() async throws {
        let (template,proof) = routeProof()
        let (storage,app,object,sender) = try fixture(template:template)
        defer { app.suspend() }
        storage.failing = true
        let entry = CatalogObject.owned(app.owners[0],object)
        await app.performAutomaticAction(entry,readiness:proof)
        storage.failing = false
        await app.performAutomaticAction(entry,readiness:proof)
        XCTAssertTrue(sender.calls.isEmpty); XCTAssertTrue(app.journal.isEmpty)
    }

    func testLocalWebhookWorksWithoutOwnerServerAndPersistsAttemptBeforePOST() async throws {
        let (storage, app, object, sender) = try fixture()
        defer { app.ownerControl.suspend() }
        sender.beforeSend = { XCTAssertEqual(storage.state?.journal?.count, 1) }
        let intent = try XCTUnwrap(app.ownerActionIntent(server:"fixture.invalid",objectID:object.id))
        await app.execute(intent)
        XCTAssertEqual(sender.calls.count,1)
        XCTAssertEqual(sender.calls[0].0,"http://relay.invalid/open")
        XCTAssertEqual(app.journal.count,1)
        XCTAssertEqual(app.journal.first?.result,"Ответ приёмника")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:sender.calls[0].1) as? [String:Any])
        XCTAssertEqual(json["object_id"] as? Int,7)
        XCTAssertEqual((json["signature"] as? String)?.count,64)
    }
    func testStorageFailurePreventsPOSTAndLostReplyDoesNotReplay() async throws {
        let (storage, app, object, sender) = try fixture()
        defer { app.ownerControl.suspend() }
        storage.failing = true
        await app.ownerControl.phoneWebhook(server:"fixture.invalid",objectID:object.id)
        XCTAssertTrue(sender.calls.isEmpty)
        storage.failing = false; sender.loseReply = true
        await app.ownerControl.phoneWebhook(server:"fixture.invalid",objectID:object.id)
        XCTAssertEqual(sender.calls.count,1)
        XCTAssertEqual(app.journal.first?.level,"danger")
        let restarted = AppModel(storage:storage,ownerAPI:OfflineWebhookOwnerAPI())
        XCTAssertEqual(restarted.journal.count,1)
        XCTAssertEqual(sender.calls.count,1)
    }
    func testSecondTapCannotSendDuringAnUnfinishedPOST() async throws {
        let (_, app, object, sender) = try fixture()
        defer { app.ownerControl.suspend() }
        sender.holding = true
        let first = Task { await app.ownerControl.phoneWebhook(server:"fixture.invalid",objectID:object.id) }
        for _ in 0..<100 where sender.continuation == nil { await Task.yield() }
        guard let continuation = sender.continuation else { first.cancel(); XCTFail("POST was not started"); return }
        XCTAssertNil(app.ownerActionIntent(server:"fixture.invalid",objectID:object.id))
        await app.ownerControl.phoneWebhook(server:"fixture.invalid",objectID:object.id)
        XCTAssertEqual(sender.calls.count,1)
        continuation.resume(returning:try PhoneWebhook.reply(status:204,data:Data()))
        await first.value
        XCTAssertEqual(app.journal.count,1)
    }
}
