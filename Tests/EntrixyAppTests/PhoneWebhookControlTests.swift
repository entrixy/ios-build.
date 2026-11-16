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
    private func fixture() throws -> (WebhookStateStorage, AppModel, OwnerObject, RecordingPhoneWebhook) {
        let storage = WebhookStateStorage()
        var owner = try OwnerAccount(server: "fixture.invalid")
        owner.credentials = try OwnerCredentials(deviceID: String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Webhook", kind: "webhook",
            url: "http://relay.invalid/open", secret: "owner-only", webhookMode: "phone")
        object.numberID = 7; object.revision = 1; object.available = true; object.pending = nil
        owner.objects = [object]
        storage.state = SavedState(identity: Data(repeating: 24,count:32), guests: [], owners:[owner])
        let app = AppModel(storage: storage, ownerAPI: OfflineWebhookOwnerAPI())
        let sender = RecordingPhoneWebhook()
        app.ownerControl = OwnerControlModel(app: app, webhook: sender)
        app.ownerControl.resume()
        return (storage, app, object, sender)
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
