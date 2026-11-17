import XCTest
import EntrixyCore
@testable import Entrixy

private final class PresentationStorage: StateStorage {
    var state: SavedState?
    var writes = 0
    init() throws { state = SavedState(identity:Data(repeating:17,count:32),guests:[],owners:[try OwnerAccount(server:"fixture.invalid")]) }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { writes += 1; self.state = state }
}
private struct PresentationOwnerAPI: OwnerTransport {
    func register(server: String,accessCode: String) async throws -> OwnerCredentials { XCTFail("Backup presentation must not register an owner"); throw BackupFailure.noAccess }
    func sync(server: String,credentials: OwnerCredentials,fingerprint: String) async throws -> Data { XCTFail("Export never contacts a server"); throw BackupFailure.noAccess }
}

@MainActor final class BackupPresentationTests: XCTestCase {
    func testCancelledPasswordAndFileExportDoNotChangeKeysOrMarkBackupSaved() async throws {
        let storage = try PresentationStorage(), app = AppModel(storage:storage,ownerAPI:PresentationOwnerAPI())
        defer { app.suspend() }
        let manager = BackupManager(app:app,refreshAfterRestore:false), flow = BackupPresentation(app:app,manager:manager)
        let original = storage.state!.identity, before = storage.writes
        let date = UserDefaults.standard.double(forKey:"entrixy.backup.at")
        flow.beginExport(); flow.password = "example-password"; flow.repeated = "example-password"
        flow.cancel()
        XCTAssertNil(flow.prompt); XCTAssertTrue(flow.password.isEmpty); XCTAssertEqual(storage.writes,before)
        flow.beginExport(); flow.password = "example-password"; flow.repeated = "example-password"
        await flow.prepareExport(send:false)
        XCTAssertTrue(flow.exporting); XCTAssertNotNil(manager.exportData)
        XCTAssertTrue(flow.password.isEmpty); XCTAssertTrue(flow.repeated.isEmpty)
        flow.didExport(.failure(NSError(domain:NSCocoaErrorDomain,code:NSUserCancelledError)))
        XCTAssertEqual(UserDefaults.standard.double(forKey:"entrixy.backup.at"),date)
        XCTAssertNil(manager.exportData); XCTAssertEqual(storage.state?.identity,original)
        XCTAssertEqual(storage.writes,before)
    }
    func testFileReaderRejectsOversizedProviderFilesBeforeTheyCanBecomeRestorePlans() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ekb")
        defer { try? FileManager.default.removeItem(at:url) }
        try Data("public fixture".utf8).write(to:url)
        XCTAssertEqual(try BackupPresentation.readFile(url),Data("public fixture".utf8))
        let handle = try FileHandle(forWritingTo:url)
        try handle.truncate(atOffset:UInt64(BackupEnvelope.maxPayloadSize + 59)); try handle.close()
        XCTAssertThrowsError(try BackupPresentation.readFile(url))
    }
}
