import XCTest
import EntrixyCore
@testable import Entrixy

private final class WidgetAccessMemory: StateStorage {
    var state: SavedState
    init(_ state: SavedState) { self.state = state }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { self.state = state }
}

@MainActor final class WidgetFlowTests: XCTestCase {
    private func fixture(policy: String = #"{"confirm_on":true}"#) throws -> (AppModel,WidgetAccessMemory,String) {
        var owner = try OwnerAccount(importing:"owner.invalid",masterKey:Data(repeating:12,count:32),
            credentials:OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64)))
        var object = try OwnerObject(masterKey:owner.masterKey,label:"Свои ворота",kind:"call",phone:"+70000000000")
        object.numberID = 7; object.pending = nil; object.available = true; object.revision = 1
        object.localPolicy = Data(policy.utf8); owner.objects = [object]
        let storage = WidgetAccessMemory(SavedState(identity:Data(repeating:28,count:32),guests:[],owners:[owner]))
        let app = AppModel(storage:storage)
        // No fixture can hand a call to iOS, even if a guard regresses.
        app.ownerControl = OwnerControlModel(app:app,dialer:{ _ in XCTFail("Widget must retain the action gate"); return false })
        return (app,storage,WidgetObjectID.forTarget(.owned(server:owner.server,objectID:object.id)))
    }
    func testTapWaitsForAppReadinessAndUsesExistingConfirmationExactlyOnce() async throws {
        let (app,storage,id) = try fixture(); defer { app.suspend() }
        let inbox = WidgetActionInbox(automaticallyDispatches:false), invocation = UUID()
        XCTAssertTrue(inbox.enqueue(id,id:invocation)); await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        inbox.bind(app); await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        inbox.setReady(true); await inbox.dispatchPending()
        let prompt = try XCTUnwrap(app.actionPrompt)
        XCTAssertEqual(prompt.target,app.controlObjects[0].target)
        // A second tap while the first gate is open cannot wait behind that
        // gate and become another physical command after the user confirms.
        XCTAssertFalse(inbox.enqueue(id))
        XCTAssertTrue(app.journal.isEmpty); app.dismissActionPrompt(prompt.id)
        XCTAssertFalse(inbox.enqueue(id,id:invocation)); await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        XCTAssertEqual(storage.state.identity,Data(repeating:28,count:32)); XCTAssertTrue(storage.state.journal?.isEmpty ?? true)
        inbox.cancel()
    }
    func testColdLockedAppRequiresEntryUnlockAndStillAsksForObjectPIN() async throws {
        let (configured,storage,id) = try fixture(policy:#"{"auth_on":true,"auth":"pin"}"#)
        defer { configured.suspend() }
        try await configured.setActionCode("1234")
        let enabled = try await configured.configureEntryLock(enabled:true,biometric:false,code:"")
        XCTAssertTrue(enabled)
        let app = AppModel(storage:storage); defer { app.suspend() }
        let inbox = WidgetActionInbox(automaticallyDispatches:false); inbox.bind(app); inbox.setReady(true)
        XCTAssertTrue(app.appLocked); XCTAssertTrue(inbox.enqueue(id)); await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        let wrong = try await app.unlockApplication(code:"0000"); XCTAssertFalse(wrong)
        await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        let unlocked = try await app.unlockApplication(code:"1234"); XCTAssertTrue(unlocked)
        await inbox.dispatchPending()
        let prompt = try XCTUnwrap(app.actionPrompt)
        XCTAssertEqual(prompt.target,app.controlObjects[0].target)
        XCTAssertTrue(app.journal.isEmpty); inbox.cancel()
    }
    func testExpiredTapAndBackgroundCancellationCannotOpenConfirmationOnLaterReturn() async throws {
        let (app,_,id) = try fixture(); defer { app.suspend() }
        var date = Date()
        let inbox = WidgetActionInbox(automaticallyDispatches:false,now:{ date }); inbox.bind(app)
        XCTAssertTrue(inbox.enqueue(id)); date = date.addingTimeInterval(61)
        inbox.setReady(true); await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        XCTAssertTrue(inbox.enqueue(id)); inbox.cancel(); inbox.setReady(true)
        await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        XCTAssertTrue(inbox.enqueue(String(repeating:"f",count:64))); await inbox.dispatchPending(); XCTAssertNil(app.actionPrompt)
        XCTAssertTrue(app.journal.isEmpty); inbox.cancel()
    }
    func testSharedCatalogContainsPresentationOnlyAndCorruptionNeverCreatesAnAction() throws {
        let (app,storage,id) = try fixture(); defer { app.suspend() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let publisher = WidgetPresentationPublisher(directory:directory)
        let catalog = try publisher.publish(app)
        XCTAssertEqual(catalog.objects.map(\.id),[id]); XCTAssertEqual(catalog.objects[0].label,"Свои ворота")
        XCTAssertEqual(WidgetCatalog.load(directory:directory),catalog)
        let bytes = try Data(contentsOf:directory.appendingPathComponent("catalog.json"))
        let text = String(decoding:bytes,as:UTF8.self)
        for secret in ["owner.invalid","+70000000000",GuestCrypto.base64URL(storage.state.identity),String(repeating:"b",count:64)] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(try directory.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        XCTAssertEqual(catalog.objects[0].currentStatus(at:Date().addingTimeInterval(60)),.ready)
        let remote = WidgetObject(id:id,label:"Remote",source:"Guest",preset:0,image:nil,status:.ready,localCall:false,observedAt:Date())
        XCTAssertEqual(remote.currentStatus(at:Date().addingTimeInterval(60)),.offline)
        XCTAssertNil(WidgetCatalog.imageURL("../../Library/credentials",directory:directory))
        try Data(#"{"objects":[{"id":"entrixy://fire"}]}"#.utf8).write(to:directory.appendingPathComponent("catalog.json"))
        XCTAssertTrue(WidgetCatalog.load(directory:directory).objects.isEmpty)
        XCTAssertTrue(app.journal.isEmpty); XCTAssertEqual(storage.state.identity,Data(repeating:28,count:32))
    }
}
