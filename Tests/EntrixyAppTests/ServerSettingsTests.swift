import XCTest
@testable import EntrixyCore
@testable import Entrixy

private final class ServerStorage: StateStorage {
    var state: SavedState?
    var failSave = false
    init(_ state: SavedState = SavedState(identity:Data(repeating:72,count:32),guests:[])) { self.state = state }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { if failSave { throw KeychainStore.Failure(status:-1) }; self.state = state }
}
private final class ServerAPI: OwnerTransport {
    let credentials = try! OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
    var registrations = 0, logins = 0, links = 0, mutations = 0
    var suite = true
    var registrationError: Error?
    var loseLinkReply = false
    var syncError: Error?
    var account: String? = nil
    var beforeRegister: (() -> Void)?
    var beforeLink: (() -> Void)?
    var registeredCode: String?, registeredToken: String?
    func supportsOwnerSuite(server: String) async throws -> Bool { suite }
    func accountLogin(server: String,email: String,password: String) async throws -> String {
        XCTAssertEqual(server,"owner.invalid"); XCTAssertEqual(email,"new@example.test"); XCTAssertEqual(password,"not-a-stored-password")
        logins += 1; return "not-a-stored-token"
    }
    func register(server: String,accessCode: String) async throws -> OwnerCredentials { try await register(server:server,accessCode:accessCode,accountToken:nil) }
    func register(server: String,accessCode: String,accountToken: String?) async throws -> OwnerCredentials {
        registrations += 1; registeredCode = accessCode; registeredToken = accountToken
        beforeRegister?(); if let registrationError { throw registrationError }
        if accountToken != nil { account = "new@example.test" }
        return credentials
    }
    func linkAccount(server: String,credentials: OwnerCredentials,token: String?) async throws -> String? {
        XCTAssertEqual(server,"owner.invalid"); links += 1; beforeLink?()
        account = token == nil ? nil : "new@example.test"
        if loseLinkReply { throw URLError(.networkConnectionLost) }
        return account
    }
    func sync(server: String,credentials: OwnerCredentials,fingerprint: String) async throws -> Data {
        if let syncError { throw syncError }
        return try JSONSerialization.data(withJSONObject:["numbers":[],"keys":[],"account":account.map { $0 as Any } ?? NSNull()])
    }
    func mutate(server: String,credentials: OwnerCredentials,fingerprint: String,operation: OwnerOperation,body: Data) async throws -> Data { mutations += 1; throw GuestCrypto.Failure.invalidEnvelope }
}

@MainActor final class ServerSettingsTests: XCTestCase {
    private func registered(_ host: String = "owner.invalid",api: ServerAPI) throws -> OwnerAccount {
        var owner = try OwnerAccount(server:host); owner.credentials = api.credentials; owner.registrationPhase = nil; return owner
    }
    func testAccountRegistrationPersistsIntentBeforeWireAndRetainsNeitherPasswordNorToken() async throws {
        let store = ServerStorage(), api = ServerAPI()
        let model = AppModel(storage:store,ownerAPI:api); defer { model.suspend() }
        api.beforeRegister = {
            XCTAssertEqual(store.state?.owners?.first?.registrationPhase,.sent)
            XCTAssertEqual(store.state?.owners?.first?.serverSettings?.pendingAccount?.email,"new@example.test")
            XCTAssertEqual(store.state?.owners?.first?.serverSettings?.pendingAccount?.sent,true)
        }
        let ok = await model.saveServerConfiguration(server:"https://owner.invalid/",accessCode:"private-code",email:"new@example.test",password:"not-a-stored-password")
        XCTAssertTrue(ok); XCTAssertEqual(api.registrations,1); XCTAssertEqual(api.registeredCode,"private-code"); XCTAssertEqual(api.registeredToken,"not-a-stored-token")
        XCTAssertEqual(model.selectedOwnerServer,"owner.invalid")
        XCTAssertEqual(store.state?.owners?.first?.serverSettings?.accountEmail,"new@example.test")
        XCTAssertNil(store.state?.owners?.first?.serverSettings?.pendingAccount)
        let encoded = String(decoding:try JSONEncoder().encode(store.state),as:UTF8.self)
        XCTAssertFalse(encoded.contains("not-a-stored-password")); XCTAssertFalse(encoded.contains("not-a-stored-token"))
    }
    func testDefiniteCodeRejectionAllowsExplicitRetryWithSameMasterButLostReplyDoesNot() async throws {
        let store = ServerStorage(), api = ServerAPI(), app = AppModel(storage:store,ownerAPI:api); defer { app.suspend() }
        api.registrationError = OwnerAPI.Failure(status:403,code:"access_denied")
        let first = await app.saveServerConfiguration(server:"owner.invalid",accessCode:"wrong",email:"",password:"")
        XCTAssertFalse(first); XCTAssertEqual(app.owners[0].registrationPhase,.rejected)
        let master = app.owners[0].masterKey
        api.registrationError = URLError(.networkConnectionLost)
        let second = await app.saveServerConfiguration(server:"owner.invalid",accessCode:"corrected",email:"",password:"")
        XCTAssertFalse(second); XCTAssertEqual(api.registrations,2); XCTAssertEqual(app.owners[0].masterKey,master)
        let restarted = AppModel(storage:store,ownerAPI:api); defer { restarted.suspend() }
        let third = await restarted.saveServerConfiguration(server:"owner.invalid",accessCode:"corrected",email:"new@example.test",password:"not-a-stored-password")
        XCTAssertFalse(third); XCTAssertEqual(api.registrations,2); XCTAssertEqual(api.logins,0)
        XCTAssertEqual(restarted.owners[0].masterKey,master); XCTAssertEqual(restarted.owners[0].registrationPhase,.sent)
    }
    func testSuiteMismatchCannotRegisterOrLogIn() async throws {
        let store = ServerStorage(), api = ServerAPI(); api.suite = false
        let app = AppModel(storage:store,ownerAPI:api); defer { app.suspend() }
        let ok = await app.saveServerConfiguration(server:"owner.invalid",accessCode:"",email:"new@example.test",password:"not-a-stored-password")
        XCTAssertFalse(ok); XCTAssertTrue(app.owners.isEmpty); XCTAssertEqual(api.registrations,0); XCTAssertEqual(api.logins,0)
    }
    func testLostAccountReplyReconcilesWithoutRegistrationOrNewSecrets() async throws {
        let api = ServerAPI(); var owner = try registered(api:api); var settings = OwnerServerSettings()
        settings.accountEmail = "old@example.test"; owner.serverSettings = settings
        let store = ServerStorage(SavedState(identity:Data(repeating:72,count:32),guests:[],owners:[owner]))
        let app = AppModel(storage:store,ownerAPI:api); defer { app.suspend() }
        api.loseLinkReply = true
        api.beforeLink = { XCTAssertEqual(store.state?.owners?.first?.serverSettings?.pendingAccount?.sent,true) }
        let ok = await app.saveServerConfiguration(server:"owner.invalid",accessCode:"private-code",email:"new@example.test",password:"not-a-stored-password")
        XCTAssertFalse(ok); XCTAssertEqual(api.registrations,0); XCTAssertEqual(api.links,1)
        XCTAssertEqual(app.owners[0].serverSettings?.accountEmail,"old@example.test")
        XCTAssertEqual(app.owners[0].serverSettings?.pendingAccount?.email,"new@example.test")
        await app.refreshOwners()
        XCTAssertEqual(app.owners[0].serverSettings?.accountEmail,"new@example.test"); XCTAssertNil(app.owners[0].serverSettings?.pendingAccount)
        XCTAssertEqual(app.owners[0].masterKey,owner.masterKey); XCTAssertEqual(app.owners[0].credentials,owner.credentials)
        api.loseLinkReply = false
        let unlinked = await app.unlinkServerAccount("owner.invalid")
        XCTAssertTrue(unlinked); XCTAssertNil(app.owners[0].serverSettings?.accountEmail); XCTAssertEqual(api.registrations,0)
    }
    func testForgetIsAtomicLocalOnlyAndPreservesSameServerReceivedAccessAndOtherOwner() throws {
        let api = ServerAPI(), owner = try registered(api:api), other = try registered("other.invalid",api:api)
        let invite = try GuestInvite.parse("https://owner.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating:"A",count:43))
        let guest = SavedGuest(invite:invite)
        let history = JournalEntry(who:"Я",what:"Ворота",actionKey:"actual-recorded-action",result:"Результат неизвестен",level:"warning")
        let owned = ObjectReference.owned(server:owner.server,objectID:UUID()), received = ObjectReference.received(guestID:guest.id,objectID:"n:7")
        let preferences = ObjectCatalogPreferences(order:[owned,received])
        let store = ServerStorage(SavedState(identity:Data(repeating:72,count:32),guests:[guest],journal:[history],owners:[owner,other],objectPreferences:preferences,selectedOwnerServer:owner.server))
        let app = AppModel(storage:store,ownerAPI:api); defer { app.suspend() }
        store.failSave = true
        XCTAssertFalse(app.forgetOwnerServer(owner.server)); XCTAssertEqual(app.owners.count,2); XCTAssertEqual(app.selectedOwnerServer,owner.server)
        XCTAssertEqual(app.objectPreferences,preferences)
        store.failSave = false
        XCTAssertTrue(app.forgetOwnerServer(owner.server)); XCTAssertEqual(app.owners,[other]); XCTAssertEqual(app.selectedOwnerServer,"entrixy.com")
        XCTAssertEqual(app.guests.map(\.invite),[invite]); XCTAssertEqual(app.journal.map(\.id),[history.id]); XCTAssertEqual(app.objectPreferences.order,[received])
        XCTAssertEqual(api.registrations,0); XCTAssertEqual(api.links,0); XCTAssertEqual(api.mutations,0)
        let restarted = AppModel(storage:store,ownerAPI:api); defer { restarted.suspend() }
        XCTAssertEqual(restarted.owners,[other]); XCTAssertEqual(restarted.guests.map(\.invite),[invite]); XCTAssertEqual(restarted.selectedOwnerServer,"entrixy.com")
        XCTAssertFalse(restarted.forgetOwnerServer("entrixy.com"))
    }
    func testSelectionFailureRollsBackAndSuccessfulSelectionSurvivesRelaunch() throws {
        let api = ServerAPI(), owner = try registered(api:api)
        let store = ServerStorage(SavedState(identity:Data(repeating:72,count:32),guests:[],owners:[owner],selectedOwnerServer:"entrixy.com"))
        let app = AppModel(storage:store,ownerAPI:api); defer { app.suspend() }
        store.failSave = true; XCTAssertFalse(app.selectOwnerServer(owner.server)); XCTAssertEqual(app.selectedOwnerServer,"entrixy.com")
        store.failSave = false; XCTAssertTrue(app.selectOwnerServer(owner.server)); XCTAssertFalse(app.selectOwnerServer("unregistered.invalid"))
        let restarted = AppModel(storage:store,ownerAPI:api); defer { restarted.suspend() }
        XCTAssertEqual(restarted.selectedOwnerServer,owner.server); XCTAssertEqual(restarted.owners,[owner]); XCTAssertEqual(api.registrations,0)
    }
    func testExplicitOwnershipDenialPersistsAndOrdinarySyncCannotReactivateIt() async throws {
        let api = ServerAPI(), owner = try registered(api:api)
        let store = ServerStorage(SavedState(identity:Data(repeating:72,count:32),guests:[],owners:[owner]))
        let app = AppModel(storage:store,ownerAPI:api); defer { app.suspend() }
        api.syncError = OwnerAPI.Failure(status:403,code:"wrong_device")
        await app.refreshOwners()
        XCTAssertEqual(app.owners[0].ownershipLost,true); XCTAssertFalse(app.ownerAccessIsUsable(owner.server))
        XCTAssertEqual(store.state?.owners?.first?.ownershipLost,true)
        api.syncError = nil; await app.refreshOwners()
        XCTAssertFalse(app.ownerAccessIsUsable(owner.server)); XCTAssertEqual(app.owners[0].masterKey,owner.masterKey)
        XCTAssertEqual(api.registrations,0)
    }
}
