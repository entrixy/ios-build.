import XCTest
import EntrixyCore
@testable import Entrixy

private final class MessageStorage: StateStorage {
    var state: SavedState?
    var fail = false
    init(_ invite: GuestInvite) { state = SavedState(identity: Data(repeating: 37, count: 32), guests: [SavedGuest(invite: invite)]) }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { if fail { throw KeychainStore.Failure(status: -1) }; self.state = state }
}
private final class MessageAckStub: GuestMessageTransport {
    var acks: [(MessageAcknowledgement, String)] = []
    var before: ((MessageAcknowledgement) -> Void)?
    var fail = false
    func acknowledgeMessage(invite: GuestInvite, fingerprint: String, kind: MessageAcknowledgement, hash: String) async throws {
        before?(kind); acks.append((kind, hash))
        if fail { throw URLError(.networkConnectionLost) }
    }
}
@MainActor
final class MessageManagerTests: XCTestCase {
    private func invite() throws -> GuestInvite { try GuestInvite.parse("https://messages.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43)) }
    func testReceivedCipherAndActualDisplayPersistBeforeDeliveryAndReadAcknowledgements() async throws {
        let invite = try invite(), ack = MessageAckStub()
        let storage = MessageStorage(invite)
        let model = AppModel(storage: storage), manager = MessageManager(app: model, acknowledgements: ack)
        let cipher = try GuestMessageCrypto.seal("Тестовое сообщение", bundleKey: invite.bundleKey)
        ack.before = { kind in
            XCTAssertEqual(storage.state?.incomingMessages?.first?.cipher, cipher)
            XCTAssertEqual(storage.state?.incomingMessages?.first?.readAt != nil, kind == .read)
        }
        await manager.receive(cipher, guestID: invite.id)
        XCTAssertEqual(ack.acks.map { $0.0 }, [.delivered])
        XCTAssertNil(model.incomingMessages[0].readAt)
        XCTAssertEqual(try manager.text(model.incomingMessages[0]), "Тестовое сообщение")
        await manager.read(model.incomingMessages[0].id)
        XCTAssertEqual(ack.acks.map { $0.0 }, [.delivered, .read])
        XCTAssertEqual(ack.acks[0].1, GuestMessageCrypto.acknowledgementHash(cipher))
        let relaunched = AppModel(storage: storage), resumed = MessageManager(app: relaunched, acknowledgements: ack)
        await resumed.receive(cipher, guestID: invite.id)
        XCTAssertEqual(relaunched.incomingMessages.count, 1)
        XCTAssertEqual(ack.acks.count, 2)
        XCTAssertTrue(relaunched.journal.isEmpty)
        relaunched.removeKey(invite.id)
        XCTAssertTrue(relaunched.incomingMessages.isEmpty)
    }
    func testInvalidCipherAndStorageFailureNeverAcknowledgeDelivery() async throws {
        let invite = try invite(), ack = MessageAckStub()
        let storage = MessageStorage(invite)
        let model = AppModel(storage: storage), manager = MessageManager(app: model, acknowledgements: ack)
        let wrong = try GuestMessageCrypto.seal("Другой ключ", bundleKey: Data(repeating: 99, count: 32))
        await manager.receive(wrong, guestID: invite.id)
        XCTAssertTrue(ack.acks.isEmpty)
        storage.fail = true
        await manager.receive(try GuestMessageCrypto.seal("Тест", bundleKey: invite.bundleKey), guestID: invite.id)
        XCTAssertTrue(ack.acks.isEmpty)
        XCTAssertTrue(model.incomingMessages.isEmpty)
        XCTAssertEqual(storage.state?.identity, Data(repeating: 37, count: 32))
    }
    func testLostReadAcknowledgementRetriesSameCipherHashAfterRelaunchWithoutInventingAnAction() async throws {
        let invite = try invite(), ack = MessageAckStub()
        let storage = MessageStorage(invite)
        let model = AppModel(storage: storage), manager = MessageManager(app: model, acknowledgements: ack)
        let cipher = try GuestMessageCrypto.seal("Тест", bundleKey: invite.bundleKey)
        await manager.receive(cipher, guestID: invite.id)
        ack.fail = true
        await manager.read(model.incomingMessages[0].id)
        XCTAssertNotNil(storage.state?.incomingMessages?.first?.readAt)
        XCTAssertEqual(storage.state?.incomingMessages?.first?.readAcknowledged, false)
        ack.fail = false
        let relaunched = AppModel(storage: storage), resumed = MessageManager(app: relaunched, acknowledgements: ack)
        await resumed.retryAcknowledgements()
        XCTAssertEqual(ack.acks.map { $0.0 }, [.delivered, .read, .read])
        XCTAssertEqual(Set(ack.acks.map { $0.1 }).count, 1)
        XCTAssertTrue(relaunched.journal.isEmpty)
    }
    func testDelegationWelcomeReadsLocallyWithoutSendingServerAcknowledgement() async throws {
        let invite = try invite(), ack = MessageAckStub(), storage = MessageStorage(invite)
        let link = try DelegationLink(server:invite.server,group:String(repeating:"G",count:22),secret:Data(repeating:5,count:32))
        let recipient = BundleKeySeal.makeRecipient()
        var receipt = try ReceivedDelegation(importing:link,recipient:recipient,guestIDs:[invite.id])
        let cipher = try GuestCrypto.encrypt(key:link.secret,plaintext:JSONSerialization.data(withJSONObject:["from":"Анна","text":"Со двора"]))
        receipt.welcomeCipher = cipher
        var message = SavedMessage(guestID:invite.id,cipher:cipher,receivedAt:Date())
        message.delegationWelcomeGroup = link.id; message.deliveryAcknowledged = true
        storage.state = SavedState(identity:Data(repeating:37,count:32),guests:[SavedGuest(invite:invite)],receivedDelegations:[receipt],incomingMessages:[message])
        let model = AppModel(storage:storage), manager = MessageManager(app:model,acknowledgements:ack)
        defer { model.suspend() }
        storage.fail = true
        await manager.read(message.id)
        XCTAssertNil(model.incomingMessages.first?.readAt); XCTAssertTrue(ack.acks.isEmpty)
        storage.fail = false
        await manager.read(message.id); await manager.retryAcknowledgements()
        XCTAssertNotNil(storage.state?.incomingMessages?.first?.readAt)
        XCTAssertEqual(storage.state?.incomingMessages?.first?.readAcknowledged,true)
        XCTAssertTrue(ack.acks.isEmpty); XCTAssertEqual(manager.sender(message),"Анна")
    }
}

private final class MessageDelegationStub: DelegationTransport {
    let group = String(repeating: "B", count: 22)
    var children: [[String: Any]] = []
    var sent: [Data] = []
    func delegationInfo(server: String, group: String) async throws -> Data { throw BackupFailure.invalidPayload }
    func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data { throw BackupFailure.invalidPayload }
    func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite? { throw BackupFailure.invalidPayload }
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data {
        switch operation {
        case .list: return try JSONSerialization.data(withJSONObject: ["objects": [["id": 7, "depth": 2, "pool_left": 8, "native_only": 0]], "invites": [], "children": children])
        case .message: sent.append(body); return Data(#"{"ok":true}"#.utf8)
        default: throw BackupFailure.invalidPayload
        }
    }
}

extension MessageManagerTests {
    func testPassedMessageRequiresRecipientProofAndSealsOnlyToThatRecipient() async throws {
        let invite = try invite(), api = MessageDelegationStub()
        let storage = MessageStorage(invite)
        let model = AppModel(storage: storage)
        let permission = try PassSnapshot.decode(JSONSerialization.data(withJSONObject: ["objects": [["id": 7, "depth": 2, "pool_left": 8, "native_only": 0]], "invites": [], "children": []]))
        var record = try PassedAccess(server: invite.server, label: "Получатель", welcome: "", objects: [invite.id: [7: KeyObjectAccess(depth: 0, pool: 1)]], snapshots: [invite.id: permission])
        record.group = api.group; record.parts[0].sent = true; record.parts[0].code = String(repeating: "C", count: 22)
        record.parts[0].state = .awaitingOwner; record.parts[0].childID = 18
        try model.savePassedAccess(record)
        let recipient = BundleKeySeal.makeRecipient(), pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3").publicKey.rawRepresentation)
        api.children = [["id": 18, "grp": api.group, "number_ids": [7], "objects": [try KeyObjectAccess(depth: 0, pool: 1).json(id: 7)],
            "sign_pub": pub, "guest_pub": recipient.publicKey, "pass_mac": String(repeating: "0", count: 64), "vouched": 1, "ready": 0]]
        let manager = MessageManager(app: model, delegation: api)
        let blocked = await manager.send("Тест получателю", target: .passed(record.id))
        XCTAssertFalse(blocked); XCTAssertTrue(api.sent.isEmpty); XCTAssertTrue(model.outgoingMessages.isEmpty)
        api.children[0]["pass_mac"] = try DelegationProof.passMAC(secret: record.secret, group: api.group, signPublic: pub, guestPublic: recipient.publicKey)
        let sent = await manager.send("Тест получателю", target: .passed(record.id))
        XCTAssertTrue(sent)
        let row = try JSONSerialization.jsonObject(with: XCTUnwrap(api.sent.first)) as! [String: String]
        XCTAssertEqual(row["grp"], api.group)
        XCTAssertEqual(try GuestMessageCrypto.open(row["cipher"]!, bundleKey: Data(repeating: 0, count: 32), recipient: recipient), "Тест получателю")
        XCTAssertEqual(model.outgoingMessages.first?.state, .accepted)
        XCTAssertTrue(model.journal.isEmpty)
    }
    func testEncryptedBackupRetainsIncomingReadStateAndTextForTheRestoredAccess() async throws {
        let invite = try invite(), ack = MessageAckStub()
        let storage = MessageStorage(invite)
        let model = AppModel(storage: storage), manager = MessageManager(app: model, acknowledgements: ack)
        let cipher = try GuestMessageCrypto.seal("Сообщение для копии", bundleKey: invite.bundleKey)
        await manager.receive(cipher, guestID: invite.id)
        await manager.read(model.incomingMessages[0].id)
        let bytes = try BackupEnvelope.seal(JSONEncoder().encode(IOSBackupPayload(state: model.backupState())), password: "test-password")
        let payload = try JSONDecoder().decode(IOSBackupPayload.self, from: BackupEnvelope.open(bytes, password: "test-password"))
        let target = MessageStorage(invite)
        target.state = SavedState(identity: Data(repeating: 41, count: 32), guests: [])
        let restored = AppModel(storage: target)
        let plan = BackupRestorePlan(payload: payload, restoredGuests: [invite.id])
        try restored.saveBackupPlan(plan)
        try restored.activateBackupGuest(SavedGuest(invite: invite), plan: plan)
        try restored.finishBackupRestore(plan)
        XCTAssertNotNil(restored.incomingMessages.first?.readAt)
        XCTAssertEqual(try MessageManager(app: restored, acknowledgements: ack).text(restored.incomingMessages[0]), "Сообщение для копии")
        XCTAssertEqual(target.state?.identity, Data(repeating: 41, count: 32))
    }
}


extension MessageManagerTests {
    func testUnreadNoticeQueuePreservesOrderAndFailedCloseNeverAcknowledgesRead() async throws {
        let invite = try invite(), ack = MessageAckStub(), storage = MessageStorage(invite)
        let model = AppModel(storage:storage), manager = MessageManager(app:model,acknowledgements:ack)
        let first = try GuestMessageCrypto.seal("Первое",bundleKey:invite.bundleKey)
        let second = try GuestMessageCrypto.seal("Второе",bundleKey:invite.bundleKey)
        await manager.receive(first,guestID:invite.id); await manager.receive(second,guestID:invite.id)
        await manager.receive(first,guestID:invite.id)
        XCTAssertEqual(model.incomingMessages.count,2)
        let id = try XCTUnwrap(manager.nextUnreadNotice()?.id)
        XCTAssertEqual(try manager.text(XCTUnwrap(manager.nextUnreadNotice())),"Первое")
        let barrier = UUID(); model.setLocalTaskDialog(barrier,presented:true)
        XCTAssertNil(manager.nextUnreadNotice()); model.setLocalTaskDialog(barrier,presented:false)
        model.incomingMessagePromptID = id
        XCTAssertNil(manager.nextUnreadNotice())
        // Closing the app/temporarily losing presentation does not mark a display read.
        model.incomingMessagePromptID = nil; XCTAssertEqual(manager.nextUnreadNotice()?.id,id)
        storage.fail = true; XCTAssertFalse(manager.markRead(id))
        XCTAssertNil(model.incomingMessages.first(where:{ $0.id == id })?.readAt)
        XCTAssertFalse(ack.acks.contains { $0.0 == .read }); XCTAssertEqual(manager.nextUnreadNotice()?.id,id)
        storage.fail = false; XCTAssertTrue(manager.markRead(id))
        XCTAssertEqual(try manager.text(XCTUnwrap(manager.nextUnreadNotice())),"Второе")
        await manager.retryAcknowledgements()
        XCTAssertEqual(ack.acks.filter { $0.0 == .read }.count,1)
        let restored = AppModel(storage:storage), resumed = MessageManager(app:restored,acknowledgements:ack)
        XCTAssertEqual(try resumed.text(XCTUnwrap(resumed.nextUnreadNotice())),"Второе")
        XCTAssertTrue(restored.journal.isEmpty)
    }
    func testCorruptNoticeCannotShowOrAcquireReadStatusAndBackgroundCannotRead() async throws {
        let invite = try invite(), ack = MessageAckStub(), storage = MessageStorage(invite)
        let model = AppModel(storage:storage), manager = MessageManager(app:model,acknowledgements:ack)
        let wrong = SavedMessage(guestID:invite.id,cipher:try GuestMessageCrypto.seal("Чужое",bundleKey:Data(repeating:99,count:32)),receivedAt:Date())
        try model.saveMessages(incoming:[wrong])
        XCTAssertNil(manager.nextUnreadNotice()); XCTAssertFalse(manager.markRead(wrong.id))
        XCTAssertTrue(ack.acks.isEmpty); XCTAssertNil(model.incomingMessages.first?.readAt)
        let cipher = try GuestMessageCrypto.seal("Настоящее",bundleKey:invite.bundleKey)
        await manager.receive(cipher,guestID:invite.id)
        let valid = try XCTUnwrap(manager.nextUnreadNotice())
        model.suspend()
        XCTAssertNil(manager.nextUnreadNotice()); XCTAssertFalse(manager.markRead(valid.id))
        XCTAssertFalse(ack.acks.contains { $0.0 == .read }); XCTAssertTrue(model.journal.isEmpty)
    }
}
