import XCTest
@testable import EntrixyCore
@testable import Entrixy

private final class MoveStateStorage: StateStorage {
    var state: SavedState?
    var rejectLocalCommit = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if rejectLocalCommit, state.owners?.first(where: { $0.server == "target.invalid" })?.objects?.isEmpty == false {
            throw KeychainStore.Failure(status:-1)
        }
        self.state = state
    }
}
private final class MoveOwnerAPI: OwnerTransport {
    var credentials: [String:OwnerCredentials] = [:]
    var rows: [String:[[String:Any]]] = [:]
    var keyRows: [[String:Any]] = []
    var creations = 0, sourceDeletes = 0, rollbackDeletes = 0, keyEdits = 0
    var loseCreateReply = false, loseDeleteReply = false, rejectDelete = false
    var beforeMutation: ((String,OwnerOperation) -> Void)?
    func register(server: String, accessCode: String) async throws -> OwnerCredentials { XCTFail("Move must not register a new owner"); throw URLError(.badServerResponse) }
    func sync(server: String, credentials: OwnerCredentials, fingerprint: String) async throws -> Data {
        XCTAssertEqual(credentials,self.credentials[server]); XCTAssertEqual(fingerprint.count,64)
        return try JSONSerialization.data(withJSONObject:["numbers":rows[server] ?? [],"keys":server == "source.invalid" ? keyRows : []])
    }
    func mutate(server: String, credentials: OwnerCredentials, fingerprint: String, operation: OwnerOperation, body: Data) async throws -> Data {
        XCTAssertEqual(credentials,self.credentials[server]); beforeMutation?(server,operation)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any])
        switch operation {
        case .create:
            XCTAssertEqual(server,"target.invalid"); XCTAssertEqual(json["type"] as? String,"ble"); XCTAssertNil(json["ble_secret"])
            creations += 1; rows[server] = [["id":70,"type":"ble","data_cipher":json["data_cipher"]!,"data_cipher_revision":1]]
            if loseCreateReply { throw URLError(.networkConnectionLost) }
            return Data(#"{"id":70}"#.utf8)
        case .delete:
            let number = json["id"] as? Int
            if server == "source.invalid" {
                sourceDeletes += 1
                if rejectDelete { throw OwnerAPI.Failure(status:403,code:"forbidden") }
                rows[server]?.removeAll { $0["id"] as? Int == number }
                keyRows[0]["number_ids"] = [8]; keyRows[0]["objects"] = [try KeyObjectAccess().json(id:8)]
                if loseDeleteReply { throw URLError(.networkConnectionLost) }
            } else { rollbackDeletes += 1; rows[server]?.removeAll { $0["id"] as? Int == number } }
        case .keyEdit:
            XCTAssertEqual(server,"source.invalid"); keyEdits += 1
            XCTAssertEqual(json["number_ids"] as? [Int],[8])
            keyRows[0]["number_ids"] = json["number_ids"]; keyRows[0]["bundle_cipher"] = json["bundle_cipher"]
        default: XCTFail("A registry move must not pair or actuate anything"); throw URLError(.badServerResponse)
        }
        return Data(#"{"ok":1}"#.utf8)
    }
}

@MainActor final class OwnerBLEMoveTests: XCTestCase {
    private func fixture() throws -> (MoveStateStorage,MoveOwnerAPI,AppModel,OwnerObject,OwnerIssuedKey) {
        let storage = MoveStateStorage(), api = MoveOwnerAPI()
        var source = try OwnerAccount(server:"source.invalid"), target = try OwnerAccount(server:"target.invalid")
        source.credentials = try OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        target.credentials = try OwnerCredentials(deviceID:String(repeating:"c",count:32),deviceSecret:String(repeating:"d",count:64))
        for number in [7,8] {
            var pair = try BLEPairingRecord(masterKey:source.masterKey,peripheralID:UUID(),peerPublic:BLECrypto.makePair().publicKey,deviceID:UInt32(number),label:"Дверь \(number)")
            try pair.markSent()
            let head = BLECrypto.littleEndian(UInt64(number),count:4) + Data([1,0,0,0]), secret = try pair.secret(masterKey:source.masterKey)
            try pair.confirm(advertisement:head + BLECrypto.hmac(secret,head).prefix(8),masterKey:source.masterKey)
            var object = try OwnerObject(pairing:pair,masterKey:source.masterKey)
            object.numberID = number; object.revision = 1; object.pending = nil; object.available = true
            pair.objectID = object.id; source.objects = (source.objects ?? []) + [object]; source.blePairings = (source.blePairings ?? []) + [pair]
        }
        var key = try OwnerIssuedKey(owner:source,label:"Гость",numberIDs:[7,8],welcome:"",nativeOnly:false,confirmation:false)
        key.keyID = 11; key.pending = nil; key.state = .active; source.issuedKeys = [key]
        api.rows[source.server] = source.objects!.map { ["id":$0.numberID!,"type":"ble","data_cipher":$0.cipher,"data_cipher_revision":1] }
        api.rows[target.server] = []
        api.keyRows = [["id":11,"enabled":1,"mode":"auto","number_ids":[7,8],"ble_ids":[Int](),"objects":[try KeyObjectAccess().json(id:7),try KeyObjectAccess().json(id:8)],"bundle_cipher":key.bundleCipher]]
        api.credentials = [source.server:source.credentials!,target.server:target.credentials!]
        let object = source.objects![0]
        storage.state = SavedState(identity:Data(repeating:37,count:32),guests:[],owners:[source,target],objectPreferences:ObjectCatalogPreferences(order:[.owned(server:source.server,objectID:object.id)]))
        api.beforeMutation = { host, operation in
            if host == "target.invalid", operation == .create { XCTAssertEqual(storage.state?.owners?[0].bleMoves?.first?.phase,.createSent) }
        }
        return (storage,api,AppModel(storage:storage,ownerAPI:api),object,key)
    }
    func testMoveCompletesWithoutPairingAndKeepsExistingGuestIdentityAndCatalogSlot() async throws {
        let (storage,api,app,object,key) = try fixture()
        let result = await app.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertTrue(result); XCTAssertEqual(api.creations,1); XCTAssertEqual(api.sourceDeletes,1); XCTAssertEqual(api.keyEdits,1)
        XCTAssertEqual(app.owners[1].objects?.first?.id,object.id)
        XCTAssertEqual(app.owners[0].issuedKeys?.first?.wrappedSecrets,key.wrappedSecrets)
        XCTAssertEqual(app.objectPreferences.order.first,.owned(server:"target.invalid",objectID:object.id))
        XCTAssertEqual(app.owners[0].bleRevocations?.first?.revoked,true)
        XCTAssertEqual(storage.state?.identity,Data(repeating:37,count:32)); XCTAssertTrue(app.journal.isEmpty)
        app.suspend()
    }
    func testLostCreationReplyReconcilesAfterRelaunchWithoutAnotherCreate() async throws {
        let (storage,api,first,object,_) = try fixture(); api.loseCreateReply = true
        let before = await first.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertFalse(before); XCTAssertEqual(api.creations,1); XCTAssertEqual(api.sourceDeletes,0)
        XCTAssertEqual(first.owners[0].objects?.count,2)
        let resumed = AppModel(storage:storage,ownerAPI:api)
        let after = await resumed.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertTrue(after); XCTAssertEqual(api.creations,1); XCTAssertEqual(api.sourceDeletes,1)
        XCTAssertEqual(resumed.owners[1].objects?.first?.id,object.id)
        first.suspend(); resumed.suspend()
    }
    func testLostDeleteReplyDoesNotRecreateOrRepeatRemovalAfterAbsenceIsConfirmed() async throws {
        let (storage,api,first,object,_) = try fixture(); api.loseDeleteReply = true
        let before = await first.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertFalse(before); XCTAssertEqual(api.sourceDeletes,1)
        let resumed = AppModel(storage:storage,ownerAPI:api)
        let after = await resumed.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertTrue(after); XCTAssertEqual(api.creations,1); XCTAssertEqual(api.sourceDeletes,1)
        first.suspend(); resumed.suspend()
    }
    func testDefinitiveSourceRefusalRollsBackTargetWithoutRevokingOriginalGuests() async throws {
        let (_,api,app,object,key) = try fixture(); api.rejectDelete = true
        let result = await app.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertFalse(result); XCTAssertEqual(api.rollbackDeletes,1)
        XCTAssertTrue(api.rows["target.invalid"]?.isEmpty == true)
        XCTAssertEqual(app.owners[0].objects?.first?.id,object.id)
        XCTAssertEqual(app.owners[0].issuedKeys?.first?.wrappedSecrets,key.wrappedSecrets)
        XCTAssertNil(app.owners[0].bleRevocations); XCTAssertTrue(app.owners[0].bleMoves?.isEmpty == true)
        XCTAssertTrue(app.journal.isEmpty); app.suspend()
    }
    func testFailedAtomicLocalCommitRetainsSecretsAndRecoversWithoutRegistryReplay() async throws {
        let (storage,api,first,object,_) = try fixture(); storage.rejectLocalCommit = true
        let before = await first.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertFalse(before); XCTAssertEqual(first.owners[0].bleMoves?.first?.phase,.ready)
        XCTAssertEqual(storage.state?.owners?[0].objects?.first?.wrappedBLESecret,object.wrappedBLESecret)
        storage.rejectLocalCommit = false
        let resumed = AppModel(storage:storage,ownerAPI:api)
        let after = await resumed.moveBLEObject(server:"source.invalid",objectID:object.id,to:"target.invalid")
        XCTAssertTrue(after); XCTAssertEqual(api.creations,1); XCTAssertEqual(api.sourceDeletes,1)
        XCTAssertEqual(resumed.owners[1].objects?.first?.id,object.id)
        first.suspend(); resumed.suspend()
    }
}
