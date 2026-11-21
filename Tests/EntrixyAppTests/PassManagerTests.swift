import XCTest
import EntrixyCore
@testable import Entrixy

private final class PassMemoryStorage: StateStorage {
    var state: SavedState?
    var fail = false
    init(_ invite: GuestInvite) { state = SavedState(identity: Data(repeating: 23, count: 32), guests: [SavedGuest(invite: invite)]) }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { if fail { throw KeychainStore.Failure(status: -1) }; self.state = state }
}
private final class PassAPIStub: DelegationTransport {
    let group = String(repeating: "B", count: 22), code = String(repeating: "C", count: 22)
    var invitations: [[String: Any]] = []
    var children: [[String: Any]] = []
    var journalEvents: [[String: Any]] = []
    var creates = 0, lists = 0, vouches = 0, revokes = 0, edits = 0
    var loseEditReply = false
    var loseCreateReply = false, loseRevokeReply = false
    var beforeCreate: (() -> Void)?
    var afterCreate: (() -> Void)?
    var beforeRevoke: (() -> Void)?
    var onVouch: (([String: Any]) throws -> Void)?
    var beforeEdit: (([String:Any]) -> Void)?
    var scoped = false
    var allowedDepth = 2,allowedPool = 8
    private var invitationsBySource: [String:[[String:Any]]] = [:]
    private var childrenBySource: [String:[[String:Any]]] = [:]
    func delegationInfo(server: String, group: String) async throws -> Data { throw BackupFailure.invalidPayload }
    func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data { throw BackupFailure.invalidPayload }
    func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite? { throw BackupFailure.invalidPayload }
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data {
        let previousInvitations = invitations, previousChildren = children
        if scoped { invitations = invitationsBySource[invite.id] ?? []; children = childrenBySource[invite.id] ?? [] }
        defer {
            if scoped {
                invitationsBySource[invite.id] = invitations; childrenBySource[invite.id] = children
                invitations = previousInvitations; children = previousChildren
            }
        }
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        switch operation {
        case .list:
            lists += 1
            return try JSONSerialization.data(withJSONObject: ["objects": [["id": 7, "depth": allowedDepth, "pool_left": allowedPool, "native_only": 0]], "invites": invitations, "children": children, "journal": journalEvents])
        case .create:
            creates += 1; beforeCreate?()
            invitations = [["code": code, "grp": group, "status": "new", "objects": json["objects"]!]]
            afterCreate?()
            if loseCreateReply { throw URLError(.networkConnectionLost) }
            return try JSONSerialization.data(withJSONObject: ["grp": group, "code": code])
        case .edit:
            edits += 1
            beforeEdit?(json)
            let objects = json["objects"] as! [[String: Any]]
            if objects.isEmpty { children = [] }
            else {
                children[0]["objects"] = objects.map { row -> [String: Any] in
                    if row["depth"] != nil { return row }
                    return ["id": row["id"]!, "depth": 0, "pool": 1, "native_only": false]
                }
                children[0]["number_ids"] = objects.map { $0["id"]! }
                children[0]["ready"] = 0
            }
            if loseEditReply { throw URLError(.networkConnectionLost) }
        case .cancel:
            if !invitations.isEmpty { invitations[0]["status"] = "cancelled" }
        case .vouch:
            vouches += 1; try onVouch?(json)
            children[0]["vouched"] = 1
        case .revoke:
            revokes += 1; beforeRevoke?()
            children = []; if !invitations.isEmpty { invitations[0]["status"] = "cancelled" }
            if loseRevokeReply { throw URLError(.networkConnectionLost) }
        default: throw BackupFailure.invalidPayload
        }
        return Data(#"{"ok":1}"#.utf8)
    }
}

@MainActor
final class PassManagerTests: XCTestCase {
    func testSeveralRemainingLevelsAndPoolPersistBeforeWireAndCannotExceedParent() async throws {
        let source=try invite(),api=PassAPIStub(),storage=PassMemoryStorage(source)
        api.allowedDepth=4;api.allowedPool=12
        let app=AppModel(storage:storage),manager=PassManager(app:app,api:api)
        defer { app.suspend() }
        let desired=try KeyObjectAccess(depth:3,pool:7)
        api.beforeCreate = {
            XCTAssertEqual(storage.state?.passedAccess?.first?.parts.first?.objects["7"],desired)
            XCTAssertEqual(storage.state?.passedAccess?.first?.parts.first?.sent,true)
        }
        let created=await manager.create(label:"Получатель",welcome:"",objects:[source.id:[7:desired]])
        XCTAssertNotNil(created);XCTAssertEqual(api.creates,1)
        XCTAssertEqual(app.passedAccess.first?.parts.first?.objects["7"],desired)
        let objects=try XCTUnwrap(api.invitations.first?["objects"] as? [[String:Any]])
        let sent=try XCTUnwrap(objects.first)
        XCTAssertEqual(sent["depth"] as? Int,3);XCTAssertEqual(sent["pool"] as? Int,7)
        let excessiveDepth=await manager.create(label:"Недопустимый",welcome:"",objects:[source.id:[7:try KeyObjectAccess(depth:4,pool:7)]])
        let excessivePool=await manager.create(label:"Недопустимый",welcome:"",objects:[source.id:[7:try KeyObjectAccess(depth:3,pool:12)]])
        XCTAssertNil(excessiveDepth);XCTAssertNil(excessivePool)
        XCTAssertEqual(api.creates,1);XCTAssertEqual(app.passedAccess.count,1)
    }
    func testAdditionalSourcePartSavesBeforeWireAndLostReplyRecoversWithoutAnotherCreate() async throws {
        let first = try invite(), second = try GuestInvite.parse("https://sender.invalid/key#ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3" + String(repeating:"A",count:43))
        let api = PassAPIStub(), storage = PassMemoryStorage(first)
        api.scoped = true
        storage.state?.guests.append(SavedGuest(invite:second))
        let app = AppModel(storage:storage), manager = PassManager(app:app,api:api); defer { app.suspend() }
        let created = await manager.create(label:"Получатель",welcome:"private welcome",objects:[first.id:[7:try KeyObjectAccess(depth:0,pool:1)]])
        let id = try XCTUnwrap(created), old = try XCTUnwrap(app.passedAccess.first)
        storage.fail = true
        let failedSave = await manager.editObjects(id,sourceID:second.id,numberIDs:[7],access:[7:try KeyObjectAccess(depth:0,pool:2)])
        XCTAssertFalse(failedSave); XCTAssertEqual(api.creates,1); XCTAssertEqual(app.passedAccess[0].parts.count,1)
        storage.fail = false; api.loseCreateReply = true
        api.beforeCreate = { XCTAssertEqual(storage.state?.passedAccess?.first?.parts.last?.sent,true); XCTAssertEqual(storage.state?.passedAccess?.first?.secret,old.secret) }
        let uncertain = await manager.editObjects(id,sourceID:second.id,numberIDs:[7],access:[7:try KeyObjectAccess(depth:0,pool:2)])
        XCTAssertFalse(uncertain); XCTAssertEqual(api.creates,2); XCTAssertEqual(app.passedAccess[0].parts.count,2)
        let restarted = AppModel(storage:storage), resumed = PassManager(app:restarted,api:api); defer { restarted.suspend() }
        await resumed.reload(); await resumed.continueCreating(id)
        XCTAssertEqual(api.creates,2); XCTAssertEqual(restarted.passedAccess[0].secret,old.secret); XCTAssertEqual(restarted.passedAccess[0].welcomeCipher,old.welcomeCipher)
        XCTAssertEqual(restarted.passedAccess[0].parts.last?.state,.available); XCTAssertEqual(restarted.passedAccess[0].link?.url,old.link?.url)
    }
    func testChangedPerObjectRightsAreSentExplicitlyAndCannotExceedFreshParentBounds() async throws {
        let invite = try invite(), api = PassAPIStub(), storage = PassMemoryStorage(try self.invite())
        let app = AppModel(storage:storage), manager = PassManager(app:app,api:api); defer { app.suspend() }
        let created = await manager.create(label:"Получатель",welcome:"",objects:[invite.id:[7:try KeyObjectAccess(depth:0,pool:1)]])
        let id = try XCTUnwrap(created), record = try XCTUnwrap(app.passedAccess.first)
        api.invitations[0]["status"] = "redeemed"
        api.children = [["id":18,"grp":api.group,"vouched":1,"ready":1,"number_ids":[7],"objects":[try KeyObjectAccess(depth:0,pool:1).json(id:7)]]]
        await manager.reload()
        let desired = try KeyObjectAccess(depth:1,pool:3)
        api.beforeEdit = { body in
            let row = (body["objects"] as! [[String:Any]])[0]
            XCTAssertEqual(row["depth"] as? Int,1); XCTAssertEqual(row["pool"] as? Int,3)
            XCTAssertEqual(storage.state?.passedAccess?.first?.parts[0].pendingEdit?["7"],desired)
        }
        let changed = await manager.editObjects(id,sourceID:invite.id,numberIDs:[7],access:[7:desired])
        XCTAssertTrue(changed); XCTAssertEqual(api.edits,1); XCTAssertEqual(app.passedAccess[0].parts[0].objects["7"],desired)
        let tooWide = await manager.editObjects(id,sourceID:invite.id,numberIDs:[7],access:[7:try KeyObjectAccess(depth:0,pool:9)])
        XCTAssertFalse(tooWide); XCTAssertEqual(api.edits,1); XCTAssertEqual(app.passedAccess[0].secret,record.secret); XCTAssertNil(app.passedAccess[0].parts[0].pendingEdit)
    }
    private func invite() throws -> GuestInvite { try GuestInvite.parse("https://sender.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43)) }
    func testDelegatedRequestsPersistWithNoInventedResultAndDoNotReturnAfterClearOrFailedSave() async throws {
        let invite = try invite(), api = PassAPIStub(), storage = PassMemoryStorage(try self.invite())
        let app = AppModel(storage: storage), manager = PassManager(app: app, api: api)
        api.journalEvents = [["id": 11, "number_id": 7, "grp": api.group, "ts": 1000]]
        await manager.reload()
        XCTAssertEqual(app.journal.count, 1)
        XCTAssertEqual(app.journal.first?.what, "#7")
        XCTAssertEqual(app.journal.first?.who, "Гость: Переданный ключ")
        XCTAssertEqual(app.journal.first?.date, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(app.journal.first?.result, "", "Server records a request, not a confirmed opening")
        XCTAssertEqual(api.creates, 0)
        app.clearJournal()
        let relaunched = AppModel(storage: storage), reload = PassManager(app: relaunched, api: api)
        await reload.reload()
        XCTAssertTrue(relaunched.journal.isEmpty)
        api.journalEvents = [["id": 12, "number_id": 7, "grp": api.group, "ts": 1001]]
        storage.fail = true
        await reload.reload()
        XCTAssertTrue(relaunched.journal.isEmpty)
        storage.fail = false
        await reload.reload()
        XCTAssertEqual(relaunched.journal.count, 1)
        XCTAssertEqual(storage.state?.delegatedJournalLedger?.hosts[invite.server], [11, 12])
        let backup = IOSBackupPayload(state: try XCTUnwrap(storage.state))
        try backup.validate()
        XCTAssertEqual(backup.delegatedJournalLedger, storage.state?.delegatedJournalLedger)
    }

    func testLostCreateReplyRecoversSameLinkAfterRelaunchWithoutSecondCreate() async throws {
        let invite = try invite(), api = PassAPIStub()
        let storage = PassMemoryStorage(invite)
        let app = AppModel(storage: storage), manager = PassManager(app: app, api: api)
        api.loseCreateReply = true
        api.beforeCreate = { XCTAssertEqual(storage.state?.passedAccess?.first?.parts[0].sent, true) }
        let created = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: try KeyObjectAccess(depth: 0, pool: 1)]])
        let id = try XCTUnwrap(created)
        let old = try XCTUnwrap(app.passedAccess.first)
        XCTAssertNil(old.group)
        XCTAssertTrue(old.parts[0].sent)
        let relaunched = AppModel(storage: storage), resumed = PassManager(app: relaunched, api: api)
        await resumed.reload()
        let restored = try XCTUnwrap(relaunched.passedAccess.first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.secret, old.secret)
        XCTAssertEqual(restored.link?.group, api.group)
        await resumed.continueCreating(id)
        XCTAssertEqual(api.creates, 1)
        XCTAssertTrue(relaunched.journal.isEmpty)
        XCTAssertEqual(storage.state?.identity, Data(repeating: 23, count: 32))
    }
    func testRecipientMACPrecedesVouchAndLostRevokeReplyIsReadBackWithoutAnotherRequest() async throws {
        let invite = try invite(), api = PassAPIStub()
        let storage = PassMemoryStorage(invite)
        let app = AppModel(storage: storage), manager = PassManager(app: app, api: api)
        let result = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: try KeyObjectAccess(depth: 0, pool: 1)]])
        let id = try XCTUnwrap(result), record = try XCTUnwrap(app.passedAccess.first)
        let recipient = BundleKeySeal.makeRecipient(), pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3").publicKey.rawRepresentation)
        api.children = [["id": 18, "grp": api.group, "sign_pub": pub, "guest_pub": recipient.publicKey, "pass_mac": String(repeating: "0", count: 64),
            "vouched": 0, "ready": 0, "number_ids": [7], "objects": [try KeyObjectAccess(depth: 0, pool: 1).json(id: 7)]]]
        await manager.reload()
        XCTAssertEqual(api.vouches, 0)
        api.children[0]["pass_mac"] = try DelegationProof.passMAC(secret: record.secret, group: api.group, signPublic: pub, guestPublic: recipient.publicKey)
        api.onVouch = { body in
            XCTAssertTrue(try DelegationProof.verifyVouch(body["sig"] as! String,
                parentPublic: GuestCrypto.signingKey(userKey: invite.userKey).publicKey.rawRepresentation,
                server: invite.server, childID: 18, signPublic: pub, guestPublic: recipient.publicKey))
        }
        await manager.reload()
        XCTAssertEqual(api.vouches, 1)
        api.loseRevokeReply = true
        api.beforeRevoke = { XCTAssertEqual(storage.state?.passedAccess?.first?.parts[0].state, .revoking); XCTAssertTrue(storage.state?.passedAccess?.first?.parts[0].revokeSent == true) }
        await manager.revoke(id)
        XCTAssertNil(app.passedAccess.first?.link)
        await manager.reload()
        XCTAssertEqual(app.passedAccess.first?.parts[0].state, .revoked)
        XCTAssertEqual(api.revokes, 1)
        XCTAssertTrue(app.journal.isEmpty)
    }
    func testSaveFailureBeforeCreateSendsNoMutationAndAckFailureRetriesOnlySaving() async throws {
        let invite = try invite(), api = PassAPIStub()
        let storage = PassMemoryStorage(invite)
        let app = AppModel(storage: storage), manager = PassManager(app: app, api: api)
        storage.fail = true
        let blocked = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: try KeyObjectAccess(depth: 0, pool: 1)]])
        XCTAssertNil(blocked)
        XCTAssertEqual(api.creates, 0)
        storage.fail = false
        api.afterCreate = { storage.fail = true }
        _ = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: try KeyObjectAccess(depth: 0, pool: 1)]])
        XCTAssertEqual(api.creates, 1)
        let lists = api.lists
        await manager.reload()
        XCTAssertEqual(api.lists, lists)
        storage.fail = false
        await manager.reload()
        XCTAssertNotNil(app.passedAccess.first?.link)
        XCTAssertEqual(api.creates, 1)
    }
    func testPassedSecretsSurviveEncryptedBackupAndMigrationWithoutReplacingIdentity() async throws {
        let invite = try invite(), api = PassAPIStub()
        let storage = PassMemoryStorage(invite)
        let original = AppModel(storage: storage), manager = PassManager(app: original, api: api)
        _ = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: try KeyObjectAccess(depth: 0, pool: 1)]])
        let saved = try XCTUnwrap(original.passedAccess.first)
        let source = try original.backupState()
        let payload = IOSBackupPayload(state: source)
        let bytes = try BackupEnvelope.seal(JSONEncoder().encode(payload), password: "test-password")
        let decoded = try JSONDecoder().decode(IOSBackupPayload.self, from: BackupEnvelope.open(bytes, password: "test-password"))
        try decoded.validate()
        XCTAssertEqual(decoded.passedAccess?.first?.secret, saved.secret)
        let target = PassMemoryStorage(invite)
        target.state = SavedState(identity: Data(repeating: 29, count: 32), guests: [])
        let restored = AppModel(storage: target)
        let plan = BackupRestorePlan(payload: decoded, restoredOwners: [], restoredGuests: [invite.id])
        try restored.saveBackupPlan(plan)
        try restored.activateBackupGuest(SavedGuest(invite: invite), plan: plan)
        try restored.finishBackupRestore(plan)
        XCTAssertEqual(restored.passedAccess.first?.secret, saved.secret)
        XCTAssertEqual(restored.passedAccess.first?.link?.url, saved.link?.url)
        XCTAssertEqual(target.state?.identity, Data(repeating: 29, count: 32))
    }

    func testRemovingAcceptedObjectsRecoversLostReplyWithoutAnotherEdit() async throws {
        let invite = try invite(), api = PassAPIStub()
        let storage = PassMemoryStorage(invite)
        let first = AppModel(storage: storage), manager = PassManager(app: first, api: api)
        let created = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: try KeyObjectAccess(depth: 0, pool: 1)]])
        let id = try XCTUnwrap(created), record = try XCTUnwrap(first.passedAccess.first)
        let recipient = BundleKeySeal.makeRecipient(), pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3").publicKey.rawRepresentation)
        api.invitations[0]["status"] = "redeemed"
        api.children = [["id": 18, "grp": api.group, "sign_pub": pub, "guest_pub": recipient.publicKey,
            "pass_mac": try DelegationProof.passMAC(secret: record.secret, group: api.group, signPublic: pub, guestPublic: recipient.publicKey),
            "vouched": 1, "ready": 1, "number_ids": [7], "objects": [try KeyObjectAccess(depth: 0, pool: 1).json(id: 7)]]]
        await manager.reload()
        api.loseEditReply = true
        let edited = await manager.editObjects(id, sourceID: invite.id, numberIDs: [])
        XCTAssertFalse(edited)
        XCTAssertNotNil(first.passedAccess.first?.parts[0].pendingEdit)
        XCTAssertNil(first.passedAccess.first?.link)
        let relaunched = AppModel(storage: storage), resumed = PassManager(app: relaunched, api: api)
        await resumed.reload()
        XCTAssertEqual(relaunched.passedAccess.first?.parts[0].state, .revoked)
        XCTAssertNil(relaunched.passedAccess.first?.parts[0].pendingEdit)
        XCTAssertEqual(api.edits, 1)
        XCTAssertTrue(relaunched.journal.isEmpty)
    }

}
