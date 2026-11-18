import XCTest
import EntrixyCore
@testable import Entrixy

private final class DiagnosticMemory: DiagnosticStorage {
    var state = DiagnosticState()
    var failRead = false
    var failSave = false
    func load() throws -> DiagnosticState { if failRead { throw KeychainStore.Failure(status:-1) }; return state }
    func save(_ state: DiagnosticState) throws { if failSave { throw KeychainStore.Failure(status:-1) }; try state.validate(); self.state = state }
}
private final class DiagnosticAccessMemory: StateStorage {
    var state: SavedState?
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { self.state = state }
}
@MainActor private final class DiagnosticRecorder: DiagnosticTransport {
    var reports: [DiagnosticReport] = []
    var failing = false
    var beforeSend: (() -> Void)?
    func send(_ report: DiagnosticReport) async throws {
        beforeSend?(); reports.append(report)
        if failing { throw URLError(.networkConnectionLost) }
    }
}

@MainActor final class DiagnosticFlowTests: XCTestCase {
    private func fixture() -> (AppModel,AppDiagnostics,DiagnosticMemory,DiagnosticRecorder,DiagnosticAccessMemory) {
        let access = DiagnosticAccessMemory(), state = DiagnosticMemory(), api = DiagnosticRecorder()
        let app = AppModel(storage:access)
        let service = AppDiagnostics(app:app,storage:state,api:api,usesMetricKit:false)
        app.diagnostics = service
        return (app,service,state,api,access)
    }
    private func crash() throws -> DiagnosticCrash {
        try DiagnosticCrash(recordedAt:Date().addingTimeInterval(2),stack:Data(#"{"callStackTree":{"callStacks":[{"callStackRootFrames":[{"binaryName":"Entrixy","offsetIntoBinaryTextSegment":123}]}]}}"#.utf8))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("Diagnostic operation did not finish")
    }
    func testDefaultOffAndManualSendDoNotCollectCrashesOrChangeAccessAndJournal() async throws {
        let (app,service,state,api,access) = fixture(); defer { app.suspend() }
        let identity = access.state?.identity
        service.receive([try crash()],periodBegin:Date().addingTimeInterval(1))
        XCTAssertTrue(state.state.reports.isEmpty); XCTAssertTrue(api.reports.isEmpty)
        service.activate(); XCTAssertTrue(app.diagnosticConsentPrompt)
        XCTAssertTrue(service.setConsent(false)); XCTAssertFalse(app.diagnosticConsentPrompt)
        service.record(.connection_failed)
        await service.sendManual()
        XCTAssertEqual(api.reports.count,1); XCTAssertEqual(api.reports[0].kind,.manual)
        XCTAssertTrue(api.reports[0].crashes.isEmpty)
        XCTAssertEqual(api.reports[0].events.map(\.code),[.connection_failed])
        XCTAssertEqual(access.state?.identity,identity); XCTAssertTrue(app.journal.isEmpty)
        XCTAssertFalse(service.enabled); XCTAssertTrue(state.state.consent.asked)
    }
    func testConsentAndQueuedCrashAreDurableBeforeAutomaticSendAndAcknowledgment() async throws {
        let (app,service,state,api,_) = fixture(); defer { app.suspend() }
        XCTAssertTrue(service.setConsent(true))
        let accepted = try XCTUnwrap(state.state.consent.acceptedAt)
        service.receive([try crash()],periodBegin:accepted.addingTimeInterval(-1))
        XCTAssertTrue(state.state.reports.isEmpty)
        service.receive([try crash()],periodBegin:accepted.addingTimeInterval(1))
        let id = try XCTUnwrap(state.state.reports.first?.id)
        XCTAssertTrue(api.reports.isEmpty)
        api.beforeSend = { XCTAssertTrue(state.state.consent.enabled); XCTAssertEqual(state.state.reports.first?.id,id) }
        service.activate()
        try await wait { !api.reports.isEmpty && !service.sending }
        XCTAssertEqual(api.reports[0].id,id); XCTAssertTrue(state.state.reports.isEmpty)
    }
    func testFailedOptOutPausesAutomaticSendAndSuccessfulRetryPurgesPendingCrashes() async throws {
        let (app,service,state,api,_) = fixture(); defer { app.suspend() }
        XCTAssertTrue(service.setConsent(true))
        service.receive([try crash()],periodBegin:Date().addingTimeInterval(1))
        XCTAssertEqual(state.state.reports.count,1)
        state.failSave = true
        XCTAssertFalse(service.setConsent(false)); service.activate()
        await Task.yield()
        XCTAssertTrue(api.reports.isEmpty); XCTAssertEqual(state.state.reports.count,1)
        state.failSave = false; XCTAssertTrue(service.setConsent(false))
        XCTAssertTrue(state.state.reports.isEmpty); XCTAssertFalse(service.enabled)
        service.activate(); await Task.yield(); XCTAssertTrue(api.reports.isEmpty)
    }
    func testLostReplyRetainsSameReportWithoutRetryLoopAndUnreadableConsentCannotEnableSending() async throws {
        let (app,service,state,api,_) = fixture(); defer { app.suspend() }
        XCTAssertTrue(service.setConsent(true)); api.failing = true
        service.receive([try crash()],periodBegin:Date().addingTimeInterval(1))
        let id = try XCTUnwrap(state.state.reports.first?.id)
        service.activate(); try await wait { api.reports.count == 1 && !service.sending }
        service.activate(); await Task.yield()
        XCTAssertEqual(api.reports.count,1); XCTAssertEqual(state.state.reports.first?.id,id)
        service.pause(); state.failRead = true
        let unreadable = AppDiagnostics(app:app,storage:state,api:api,usesMetricKit:false)
        XCTAssertFalse(unreadable.ready); XCTAssertFalse(unreadable.setConsent(true)); unreadable.activate()
        await unreadable.sendManual(); XCTAssertEqual(api.reports.count,1)
    }
    func testDecliningConsentCannotTrapTheUserWhenOnlyDiagnosticStorageFails() async throws {
        let (app,service,state,api,_) = fixture(); defer { app.suspend() }
        state.failSave = true; service.activate(); XCTAssertTrue(app.diagnosticConsentPrompt)
        XCTAssertFalse(service.setConsent(false))
        XCTAssertFalse(app.diagnosticConsentPrompt); XCTAssertTrue(app.canManageGuestAccess)
        service.activate(); await Task.yield()
        XCTAssertFalse(app.diagnosticConsentPrompt); XCTAssertTrue(api.reports.isEmpty)
    }
}
