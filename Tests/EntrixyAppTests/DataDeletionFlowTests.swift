import XCTest
import EntrixyCore
@testable import Entrixy

private final class DeletionState: StateStorage {
    var state: SavedState?
    var failing = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { if failing { throw KeychainStore.Failure(status:-1) }; self.state = state }
}
private final class DeletionAPI: OwnerTransport {
    var requests: [DataDeletionReceipt] = [], logins = 0, mutations = 0
    var loseResponse = false
    var beforeResponse: (() -> Void)?
    func accountLogin(server:String,email:String,password:String) async throws -> String {
        XCTAssertEqual(email,"owner@example.test"); XCTAssertEqual(password,"not-stored-password"); logins += 1; return "not-stored-account-token"
    }
    func dataDeletion(server:String,credentials:OwnerCredentials?,receipt:DataDeletionReceipt,accountToken:String?,submit:Bool) async throws -> DataDeletionResult {
        if submit { XCTAssertNotNil(credentials); if receipt.scope == .account { XCTAssertEqual(accountToken,"not-stored-account-token") } }
        else { XCTAssertNil(credentials); XCTAssertNil(accountToken) }
        requests.append(receipt); beforeResponse?()
        if loseResponse { throw URLError(.networkConnectionLost) }
        return DataDeletionResult(requestID:receipt.id,scope:receipt.scope,status:.pending,requestedAt:1_700_000_000,expectedBy:1_700_086_400)
    }
    func register(server:String,accessCode:String) async throws -> OwnerCredentials { throw GuestCrypto.Failure.invalidEnvelope }
    func sync(server:String,credentials:OwnerCredentials,fingerprint:String) async throws -> Data { throw GuestCrypto.Failure.invalidEnvelope }
    func mutate(server:String,credentials:OwnerCredentials,fingerprint:String,operation:OwnerOperation,body:Data) async throws -> Data { mutations += 1; throw GuestCrypto.Failure.invalidEnvelope }
}
@MainActor final class DataDeletionFlowTests: XCTestCase {
    private func fixture(store:DeletionState = DeletionState(),api:DeletionAPI = DeletionAPI()) throws -> (AppModel,DeletionState,DeletionAPI) {
        if store.state == nil {
            var owner = try OwnerAccount(server:"deletion.invalid")
            owner.credentials = try OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64)); owner.registrationPhase = nil
            var settings = OwnerServerSettings(); settings.accountEmail = "owner@example.test"; owner.serverSettings = settings
            var state = SavedState(identity:Data(repeating:91,count:32),guests:[]); state.owners = [owner]; store.state = state
        }
        return (AppModel(storage:store,ownerAPI:api),store,api)
    }
    func testUnconfirmedRequestAndFailedDurablePreparationSendNothingAndPreserveIdentity() async throws {
        let (app,store,api) = try fixture(); defer { app.suspend() }; let original = store.state
        let outcome1 = await app.submitDataDeletion(server:"deletion.invalid",scope:.device,password:"",confirmation:"delete"); XCTAssertFalse(outcome1)
        XCTAssertTrue(api.requests.isEmpty)
        store.failing = true
        let outcome2 = await app.submitDataDeletion(server:"deletion.invalid",scope:.device,password:"",confirmation:"DELETE"); XCTAssertFalse(outcome2)
        XCTAssertTrue(api.requests.isEmpty); XCTAssertEqual(api.logins,0); XCTAssertEqual(store.state?.identity,original?.identity)
        XCTAssertNil(store.state?.owners?.first?.serverSettings?.deletionReceipt); XCTAssertTrue(app.journal.isEmpty)
    }
    func testLostResponseAndRelaunchUseSameReceiptAndNeverRepeatAControlCommand() async throws {
        let (app,store,api) = try fixture(); api.loseResponse = true
        let outcome3 = await app.submitDataDeletion(server:"deletion.invalid",scope:.device,password:"",confirmation:"DELETE"); XCTAssertFalse(outcome3)
        let receipt = try XCTUnwrap(store.state?.owners?.first?.serverSettings?.deletionReceipt); app.suspend()
        let (next,_,nextAPI) = try fixture(store:store); defer { next.suspend() }
        let outcome4 = await next.refreshDataDeletion(server:"deletion.invalid"); XCTAssertTrue(outcome4)
        XCTAssertEqual(nextAPI.requests.first?.id,receipt.id); XCTAssertEqual(nextAPI.requests.first?.token,receipt.token)
        XCTAssertEqual(next.owners.first?.serverSettings?.deletionReceipt?.result?.status,.pending)
        XCTAssertEqual(api.mutations,0); XCTAssertEqual(nextAPI.mutations,0); XCTAssertTrue(next.journal.isEmpty)
    }
    func testWholeAccountNeedsFreshAuthenticationAndNeverPersistsPasswordOrAccountToken() async throws {
        let (app,store,api) = try fixture(); defer { app.suspend() }
        let outcome5 = await app.submitDataDeletion(server:"deletion.invalid",scope:.account,password:"",confirmation:"DELETE"); XCTAssertFalse(outcome5)
        XCTAssertTrue(api.requests.isEmpty)
        let outcome6 = await app.submitDataDeletion(server:"deletion.invalid",scope:.account,password:"not-stored-password",confirmation:"DELETE"); XCTAssertTrue(outcome6)
        XCTAssertEqual(api.logins,1)
        let json = String(decoding:try JSONEncoder().encode(store.state),as:UTF8.self)
        XCTAssertFalse(json.contains("not-stored-password")); XCTAssertFalse(json.contains("not-stored-account-token"))
        XCTAssertEqual(app.owners.first?.serverSettings?.deletionReceipt?.result?.status,.pending)
        XCTAssertFalse(app.localDataErased); XCTAssertTrue(app.journal.isEmpty)
    }
    func testBackgroundCompletionCannotPublishLateStateIntoSuspendedModel() async throws {
        let (app,store,api) = try fixture(); defer { app.suspend() }
        api.beforeResponse = { app.suspend() }
        let outcome7 = await app.submitDataDeletion(server:"deletion.invalid",scope:.device,password:"",confirmation:"DELETE"); XCTAssertFalse(outcome7)
        XCTAssertNotNil(store.state?.owners?.first?.serverSettings?.deletionReceipt)
        XCTAssertNil(store.state?.owners?.first?.serverSettings?.deletionReceipt?.result)
        XCTAssertFalse(app.localDataErased); XCTAssertTrue(app.journal.isEmpty)
    }
}
