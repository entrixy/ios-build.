import XCTest
import EntrixyCore
@testable import Entrixy

private final class CompanyStorage: StateStorage {
    var state: SavedState?
    var failing = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { if failing { throw KeychainStore.Failure(status:-1) }; self.state = state }
}
private final class CompanyOwnerAPI: OwnerTransport {
    var profile: KnownCompany!
    var claims: [String] = []
    var rows: [[String:Any]] = [], keys: [[String:Any]] = []
    var mutations: [OwnerOperation] = []
    var beforeMutation: ((OwnerOperation,Data) -> Void)?
    var beforeClaim: (() -> Void)?
    var loseCreateReply = false, loseRevokeReply = false, mergeCreate = false
    var liveChannel: CompanyChannel?
    func register(server: String,accessCode: String) async throws -> OwnerCredentials { XCTFail("Company invitation must not register an owner"); throw BackupFailure.noAccess }
    func companyInvite(server: String,code: String) async throws -> KnownCompany { XCTAssertEqual(server,profile.server); return profile }
    func companyClaim(server: String,credentials: OwnerCredentials,code: String) async throws { beforeClaim?(); XCTAssertEqual(server,profile.server); claims.append(server) }
    func live(server: String,credentials: OwnerCredentials,fingerprint: String) throws -> OwnerLiveTransport { guard let liveChannel else { throw BackupFailure.noAccess }; return liveChannel }
    func sync(server: String,credentials: OwnerCredentials,fingerprint: String) async throws -> Data { try JSONSerialization.data(withJSONObject:["numbers":rows,"keys":keys]) }
    func mutate(server: String,credentials: OwnerCredentials,fingerprint: String,operation: OwnerOperation,body: Data) async throws -> Data {
        mutations.append(operation); beforeMutation?(operation,body)
        let fields = try JSONSerialization.jsonObject(with:body) as! [String:Any]
        if operation == .keyCreate {
            if mergeCreate { return Data(#"{"id":99,"org_id":11,"merged":1}"#.utf8) }
            keys.append(["id":17,"org_id":fields["org_id"]!,"enabled":1,"mode":"auto","sign_pub":fields["sign_pub"]!,"number_ids":fields["number_ids"]!,"bundle_cipher":fields["bundle_cipher"]!,"objects":fields["objects"]!])
            if loseCreateReply { throw URLError(.networkConnectionLost) }
            return Data(#"{"id":17,"org_id":11}"#.utf8)
        }
        if operation == .keyRevoke { keys[0]["enabled"] = 0; if loseRevokeReply { throw URLError(.networkConnectionLost) } }
        if operation == .keyMode { keys[0]["mode"] = fields["mode"] }
        return Data(#"{"ok":1}"#.utf8)
    }
}
private final class CompanyChannel: OwnerLiveTransport {
    let frames: AsyncThrowingStream<Data,Error>
    private let output: AsyncThrowingStream<Data,Error>.Continuation
    init() { var continuation: AsyncThrowingStream<Data,Error>.Continuation!; frames = AsyncThrowingStream { continuation = $0 }; output = continuation; emit(["type":"host_ok"]) }
    func emit(_ value: [String:Any]) { output.yield(try! JSONSerialization.data(withJSONObject:value)) }
    func sendAction(_ frame: Data) async throws {}
    func close() { output.finish() }
}

@MainActor final class CompanyModelTests: XCTestCase {
    private let userKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"
    private func fixture(granted: Bool = false) throws -> (CompanyStorage,CompanyOwnerAPI,AppModel) {
        let storage = CompanyStorage(), api = CompanyOwnerAPI()
        let publicKey = try GuestCrypto.signingKey(userKey:userKey).publicKey.rawRepresentation
        api.profile = try KnownCompany(server:"owner.invalid",json:["org_id":11,"name":"Доставка","verified":true,"domain":"delivery.example","pubkey":publicKey.base64EncodedString()],pendingCode:"CODE11")
        var owner = try OwnerAccount(server:"owner.invalid")
        owner.credentials = try OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        var object = try OwnerObject(masterKey:owner.masterKey,label:"Ворота",kind:"call",phone:"+79990001122")
        object.numberID = 7; object.pending = nil; object.available = true; object.revision = 100
        owner.objects = [object]
        api.rows = [["id":7,"type":"call","data_cipher":object.cipher,"data_cipher_revision":100]]
        if granted {
            var key = try OwnerIssuedKey.forCompany(owner:owner,profile:api.profile,numberIDs:[7])
            key.keyID = 17; key.pending = nil; key.sent = false; key.state = .active
            owner.issuedKeys = [key]
            api.keys = [["id":17,"org_id":11,"enabled":1,"mode":"auto","sign_pub":GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey:key.secrets(masterKey:owner.masterKey).userKey).publicKey.rawRepresentation),"number_ids":[7],"bundle_cipher":key.bundleCipher,"objects":[try KeyObjectAccess(depth:0,pool:1).json(id:7)]]]
        }
        storage.state = SavedState(identity:Data(repeating:32,count:32),guests:[],owners:[owner],companies:[api.profile])
        return (storage,api,AppModel(storage:storage,ownerAPI:api))
    }
    func testInvitationPersistsBeforeClaimAndNeverSendsAnotherServersCredentials() async throws {
        let (storage,api,app) = try fixture(); defer { app.suspend() }
        api.profile = try KnownCompany(server:"different.invalid",json:["org_id":11,"name":"Другая компания","verified":false],pendingCode:"CODE11")
        await app.receiveCompanyInvite(try CompanyInvite.parse("https://different.invalid/c/CODE11"))
        XCTAssertEqual(storage.state?.companies?.count,2); XCTAssertTrue(api.claims.isEmpty); XCTAssertTrue(api.mutations.isEmpty)
        api.profile = app.companies.first!
        api.beforeClaim = { XCTAssertEqual(storage.state?.companies?.first?.pendingCode,"CODE11") }
        await app.receiveCompanyInvite(try CompanyInvite.parse("https://owner.invalid/c/CODE11"))
        XCTAssertEqual(api.claims,["owner.invalid"])
        storage.failing = true
        await app.receiveCompanyInvite(try CompanyInvite.parse("https://owner.invalid/c/CODE11"))
        XCTAssertEqual(api.claims.count,1); XCTAssertEqual(app.companies.count,2)
    }
    func testLostCompanyCreationReplyReconcilesSameIdentityAndBlocksSecondGrant() async throws {
        let (storage,api,app) = try fixture(); defer { app.suspend() }
        api.loseCreateReply = true
        api.beforeMutation = { operation,body in
            if operation == .keyCreate {
                XCTAssertTrue(storage.state?.owners?[0].issuedKeys?.first?.sent == true)
                let request = try! JSONSerialization.jsonObject(with:body) as! [String:Any]
                XCTAssertEqual(request["org_id"] as? Int,11)
                XCTAssertEqual((request["org_labels"] as? [String:String])?["7"],"Ворота")
            }
        }
        let first = await app.issueCompanyAccess(profileID:api.profile.id,numberIDs:[7],calls:[:]); XCTAssertFalse(first)
        let pending = try XCTUnwrap(app.owners[0].issuedKeys?.first)
        XCTAssertTrue(pending.sent); XCTAssertNotNil(pending.company?.publicKey)
        let repeated = await app.issueCompanyAccess(profileID:api.profile.id,numberIDs:[7],calls:[:]); XCTAssertFalse(repeated)
        XCTAssertEqual(api.mutations,[.keyCreate]); XCTAssertEqual(app.owners[0].issuedKeys?.count,1)
        let confirmed = try XCTUnwrap(app.owners[0].issuedKeys?.first)
        XCTAssertNil(confirmed.pending); XCTAssertEqual(confirmed.wrappedSecrets,pending.wrappedSecrets)
        XCTAssertTrue(app.guestPeople.isEmpty); XCTAssertEqual(app.companyKeys(api.profile).count,1)
        XCTAssertTrue(app.journal.isEmpty)
        let backup = IOSBackupPayload(state:storage.state!); try backup.validate()
        XCTAssertEqual(backup.companies?.first?.publicKey,api.profile.publicKey)
    }
    func testOrdinarySyncCannotRotatePinButExplicitRequestCanAndUncertainRevocationKeepsCompany() async throws {
        let (storage,api,app) = try fixture(granted:true); defer { app.suspend() }
        let original = app.owners[0].issuedKeys![0].company?.publicKey
        api.profile.publicKey = Data(repeating:88,count:32)
        api.keys[0]["org_pubkey"] = api.profile.publicKey!.base64EncodedString()
        await app.refreshOwners()
        XCTAssertEqual(app.owners[0].issuedKeys![0].company?.publicKey,original)
        await app.receiveCompanyInvite(try CompanyInvite.parse("https://owner.invalid/c/CODE11"))
        XCTAssertEqual(app.companies[0].publicKey,api.profile.publicKey)
        XCTAssertEqual(app.owners[0].issuedKeys![0].company?.publicKey,api.profile.publicKey)
        api.loseRevokeReply = true; await app.forgetCompany(api.profile.id)
        XCTAssertEqual(app.companies.count,1); XCTAssertNotNil(app.owners[0].issuedKeys![0].pending)
        XCTAssertNil(try app.owners[0].authorizedGuest(keyID:17,numberID:7))
        await app.refreshOwners(); api.loseRevokeReply = false; await app.forgetCompany(api.profile.id)
        XCTAssertTrue(app.companies.isEmpty); XCTAssertTrue(storage.state?.companies?.isEmpty == true)
        XCTAssertEqual(app.owners[0].issuedKeys![0].company?.publicKey,api.profile.publicKey)
    }
    func testMergedResponseCannotBindNewSecretsToTheExistingServerKey() async throws {
        let (_,api,app) = try fixture(); defer { app.suspend() }
        api.mergeCreate = true
        let result = await app.issueCompanyAccess(profileID:api.profile.id,numberIDs:[7],calls:[:]); XCTAssertFalse(result)
        let pending = try XCTUnwrap(app.owners[0].issuedKeys?.first)
        XCTAssertNil(pending.keyID); XCTAssertTrue(pending.sent)
        XCTAssertNotNil(pending.pending); XCTAssertTrue(api.mutations == [.keyCreate])
        XCTAssertNil(try app.owners[0].authorizedGuest(keyID:99,numberID:7))
    }
    func testSignedCompanyCallUsesPinnedKeyAndSignedActorAndRejectsReplay() async throws {
        let (_,api,app) = try fixture(granted:true); defer { app.suspend() }
        var preference = OwnerCallPreference(); preference.reaction = "confirm"
        let keyID = app.owners[0].issuedKeys![0].id, objectID = app.owners[0].objects![0].id
        XCTAssertTrue(app.saveIssuedCallPreference(server:"owner.invalid",keyID:keyID,objectID:objectID,preference:preference))
        let channel = CompanyChannel(); api.liveChannel = channel
        var dialed = 0
        let control = OwnerControlModel(app:app,dialer:{ _ in dialed += 1; return true })
        defer { control.suspend() }; control.resume()
        for _ in 0..<200 { if control.connections["owner.invalid"] == .connected { break }; try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertEqual(control.connections["owner.invalid"],.connected)
        let body = #"{ "key_ref":17, "number_id":7, "actor":"Курьер Иван" }"#
        let ts = Int64(Date().timeIntervalSince1970), nonce = String(repeating:"c",count:32)
        let material = Data("delivery.example.\(ts).\(nonce).\(GuestCrypto.hash(Data(body.utf8)))".utf8)
        let sig = try GuestCrypto.signingKey(userKey:userKey).signature(for:material).base64EncodedString()
        let request: [String:Any] = ["type":"do_call","call_id":"company-call","number_id":7,"user_key_id":17,"press":["org":["domain":"delivery.example","ts":ts,"nonce":nonce,"body":body,"sig":sig]]]
        channel.emit(request); channel.emit(request)
        for _ in 0..<200 { if control.phoneRequests.count == 1 { break }; try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertEqual(control.phoneRequests.count,1); XCTAssertEqual(dialed,0)
        let pending = try XCTUnwrap(control.phoneRequests.first)
        await control.approve(pending)
        XCTAssertEqual(dialed,1); XCTAssertEqual(app.journal.count,1)
        XCTAssertTrue(app.journal.first?.who.contains("Курьер Иван") == true)
        channel.emit(request); try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertTrue(control.phoneRequests.isEmpty); XCTAssertEqual(dialed,1)
    }
}
