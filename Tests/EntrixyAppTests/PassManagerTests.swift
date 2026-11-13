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
    var creates = 0, lists = 0, vouches = 0, revokes = 0, edits = 0
    var loseEditReply = false
    var loseCreateReply = false, loseRevokeReply = false
    var beforeCreate: (() -> Void)?
    var afterCreate: (() -> Void)?
    var beforeRevoke: (() -> Void)?
    var onVouch: (([String: Any]) throws -> Void)?
    func delegationInfo(server: String, group: String) async throws -> Data { throw BackupFailure.invalidPayload }
    func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data { throw BackupFailure.invalidPayload }
    func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite? { throw BackupFailure.invalidPayload }
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data {
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        switch operation {
        case .list:
            lists += 1
            return try JSONSerialization.data(withJSONObject: ["objects": [["id": 7, "depth": 2, "pool_left": 8, "native_only": 0]], "invites": invitations, "children": children])
        case .create:
            creates += 1; beforeCreate?()
            invitations = [["code": code, "grp": group, "status": "new", "objects": json["objects"]!]]
            afterCreate?()
            if loseCreateReply { throw URLError(.networkConnectionLost) }
            return try JSONSerialization.data(withJSONObject: ["grp": group, "code": code])
        case .edit:
            edits += 1
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
    private func invite() throws -> GuestInvite { try GuestInvite.parse("https://sender.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43)) }
    func testLostCreateReplyRecoversSameLinkAfterRelaunchWithoutSecondCreate() async throws {
        let invite = try invite(), api = PassAPIStub()
        let storage = PassMemoryStorage(invite)
        let app = AppModel(storage: storage), manager = PassManager(app: app, api: api)
        api.loseCreateReply = true
        api.beforeCreate = { XCTAssertEqual(storage.state?.passedAccess?.first?.parts[0].sent, true) }
        let created = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: KeyObjectAccess(depth: 0, pool: 1)]])
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
        let result = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: KeyObjectAccess(depth: 0, pool: 1)]])
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
        let blocked = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: KeyObjectAccess(depth: 0, pool: 1)]])
        XCTAssertNil(blocked)
        XCTAssertEqual(api.creates, 0)
        storage.fail = false
        api.afterCreate = { storage.fail = true }
        _ = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: KeyObjectAccess(depth: 0, pool: 1)]])
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
        _ = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: KeyObjectAccess(depth: 0, pool: 1)]])
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
        let created = await manager.create(label: "Получатель", welcome: "", objects: [invite.id: [7: KeyObjectAccess(depth: 0, pool: 1)]])
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
