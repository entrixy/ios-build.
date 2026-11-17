import XCTest
import EntrixyCore
@testable import Entrixy

private final class PrivacyStateStorage: StateStorage {
    var state: SavedState?
    var failSave = false
    init(_ state: SavedState) { self.state = state }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if failSave { throw KeychainStore.Failure(status:-1) }
        self.state = state
    }
}
private struct PrivacyNoOwnerAPI: OwnerTransport {
    func register(server: String,accessCode: String) async throws -> OwnerCredentials { throw BackupFailure.noAccess }
    func sync(server: String,credentials: OwnerCredentials,fingerprint: String) async throws -> Data { throw BackupFailure.noAccess }
}

@MainActor final class NetworkPrivacyStateTests: XCTestCase {
    private func state(_ name: String,cellular: Bool = false) throws -> SavedState {
        let guest = SavedGuest(invite:try GuestInvite.parse("https://owner.invalid/key#"+String(repeating:"A",count:32)+GuestCrypto.base64URL(Data(repeating:17,count:32))),privacyNetworks:[try PrivacyNetwork(ssid:"Guest home")])
        return SavedState(identity:Data(repeating:23,count:32),guests:[guest],networkPrivacy:try NetworkPrivacyPreferences(own:[PrivacyNetwork(ssid:name)],cellularAuthorized:cellular))
    }
    func testProtectedStateRetainsConsentButExportCannotAuthorizeAnotherPhone() throws {
        let original = try state("Home",cellular:true)
        let durable = try JSONDecoder().decode(SavedState.self,from:JSONEncoder().encode(original))
        let store = PrivacyStateStorage(durable), app = AppModel(storage:store,ownerAPI:PrivacyNoOwnerAPI())
        defer { app.suspend() }
        XCTAssertTrue(app.storageReady); XCTAssertTrue(app.networkPrivacy.cellularAuthorized)
        let payload = IOSBackupPayload(state:try app.backupState()); try payload.validate()
        XCTAssertFalse(try XCTUnwrap(payload.networkPrivacy).cellularAuthorized)
        XCTAssertEqual(payload.networkPrivacy?.own.map(\.ssid),["Home"])
        XCTAssertEqual(payload.guests[0].privacyNetworks?.map(\.ssid),["Guest home"])
        XCTAssertTrue(try XCTUnwrap(store.state?.networkPrivacy).cellularAuthorized)
    }
    func testFinalRestoreSaveFailureKeepsLocalRulesAndRetryMergesWithoutCellularConsent() throws {
        let store = PrivacyStateStorage(try state("Current")), app = AppModel(storage:store,ownerAPI:PrivacyNoOwnerAPI())
        defer { app.suspend() }
        let payload = IOSBackupPayload(state:try state("Imported",cellular:true))
        let plan = BackupRestorePlan(payload:payload)
        try app.saveBackupPlan(plan)
        store.failSave = true
        XCTAssertThrowsError(try app.finishBackupRestore(plan))
        XCTAssertEqual(app.networkPrivacy.own.map(\.ssid),["Current"])
        XCTAssertNotNil(app.backupPlan())
        XCTAssertEqual(store.state?.networkPrivacy?.own.map(\.ssid),["Current"])
        store.failSave = false; try app.finishBackupRestore(plan)
        XCTAssertEqual(app.networkPrivacy.own.map(\.ssid),["Current","Imported"])
        XCTAssertFalse(app.networkPrivacy.cellularAuthorized); XCTAssertNil(app.backupPlan())
        let restarted = AppModel(storage:store,ownerAPI:PrivacyNoOwnerAPI()); defer { restarted.suspend() }
        XCTAssertEqual(restarted.networkPrivacy,app.networkPrivacy)
    }
}
