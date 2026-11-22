import XCTest
import EntrixyCore
@testable import Entrixy

private final class DelegationStorage: StateStorage {
    var state: SavedState? = SavedState(identity: Data(repeating: 19, count: 32), guests: [])
    var fail = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if fail { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}
private final class DelegationAPIStub: DelegationTransport {
    var redeems = 0
    var resolves = 0
    var loseReply = false
    var ready = false
    var extraPart = false
    var redeemedCodes: [[String]] = []
    var recipientPublicKeys: [String] = []
    var beforeRedeem: ((DelegationRedemption) -> Void)?
    var afterInfo: (() -> Void)?
    var welcomeCipher: String?
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data { throw BackupFailure.invalidPayload }
    func delegationInfo(server: String, group: String) async throws -> Data {
        var parts = [["code": String(repeating: "B", count: 22), "state": extraPart ? "redeemed" : "new"]]
        if extraPart { parts.append(["code": String(repeating: "C", count: 22), "state": "new"]) }
        var json: [String:Any] = ["grp": group, "state": "new", "parts": parts]
        if let welcomeCipher { json["welcome_cipher"] = welcomeCipher }
        afterInfo?()
        return try JSONSerialization.data(withJSONObject:json)
    }
    func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data {
        redeems += 1; beforeRedeem?(pending)
        redeemedCodes.append(pending.parts.map(\.code)); recipientPublicKeys.append(pending.recipient.publicKey)
        if loseReply { throw URLError(.networkConnectionLost) }
        return Data(#"{"ok":1,"state":"awaiting_owner"}"#.utf8)
    }
    func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite? {
        resolves += 1
        if !ready { return nil }
        return try pending.invitation(part: part, keyCipher: BundleKeySeal.seal(Data(repeating: 7, count: 32), recipientPublicKey: pending.recipient.publicKey))
    }
}

@MainActor
final class DelegationInboxTests: XCTestCase {
    private func link() throws -> DelegationLink { try DelegationLink(server: "controller.invalid", group: String(repeating: "A", count: 22), secret: Data(repeating: 5, count: 32)) }
    func testLostReplyPreservesRecipientBeforeRequestAndNeverRedeemsTwiceAfterRelaunch() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub()
        // Use one durable store for both app instances below.
        let first = AppModel(storage: storage)
        let manager = DelegationInbox(app: first, api: api, automaticUpdates: false)
        await manager.inspect(try link().url)
        XCTAssertEqual(api.redeems, 0)
        api.beforeRedeem = { pending in
            XCTAssertTrue(storage.state!.delegations![0].sent)
            XCTAssertEqual(storage.state!.delegations![0].recipient.privateKey, pending.recipient.privateKey)
        }
        api.loseReply = true
        await manager.accept()
        let saved = try XCTUnwrap(storage.state?.delegations?.first)
        let second = AppModel(storage: storage), resumed = DelegationInbox(app: second, api: api, automaticUpdates: false)
        await resumed.send(saved.id)
        XCTAssertEqual(api.redeems, 1)
        api.ready = true
        await resumed.check(saved.id)
        XCTAssertTrue(second.delegations.isEmpty)
        XCTAssertEqual(second.receivedDelegations.first?.recipient.privateKey, saved.recipient.privateKey)
        XCTAssertEqual(second.guests.count, 1)
        XCTAssertEqual(second.guests[0].invite.userKey, saved.parts[0].userKey)
        XCTAssertEqual(storage.state?.identity, Data(repeating: 19, count: 32))
        XCTAssertTrue(second.journal.isEmpty)
        second.removeKey(second.guests[0].id)
        XCTAssertTrue(second.receivedDelegations.isEmpty)
    }
    func testFailedReservationSendsNothing() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub()
        let app = AppModel(storage: storage), manager = DelegationInbox(app: app, api: api, automaticUpdates: false)
        await manager.inspect(try link().url)
        storage.fail = true
        await manager.accept()
        XCTAssertEqual(api.redeems, 0)
        XCTAssertTrue(app.delegations.isEmpty)
        XCTAssertTrue(app.guests.isEmpty)
    }
    func testActivationWriteFailureRetainsOriginalRecipientForSafeCheck() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub()
        let app = AppModel(storage: storage), manager = DelegationInbox(app: app, api: api, automaticUpdates: false)
        await manager.inspect(try link().url)
        await manager.accept()
        let pending = try XCTUnwrap(app.delegations.first)
        api.ready = true; storage.fail = true
        await manager.check(pending.id)
        XCTAssertTrue(app.guests.isEmpty)
        XCTAssertEqual(app.delegations.first?.recipient.privateKey, pending.recipient.privateKey)
        storage.fail = false
        await manager.check(pending.id)
        XCTAssertEqual(api.redeems, 1)
        XCTAssertEqual(app.guests.count, 1)
        XCTAssertTrue(app.delegations.isEmpty)
    }
    func testAdditionalPartKeepsInstalledKeysAndRecipientPairWithoutRedeemingOldCodesAgain() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub()
        let app = AppModel(storage: storage), manager = DelegationInbox(app: app, api: api, automaticUpdates: false)
        api.ready = true
        await manager.inspect(try link().url)
        await manager.accept()
        let original = try XCTUnwrap(app.guests.first), pair = try XCTUnwrap(app.receivedDelegations.first?.recipient)
        XCTAssertTrue(app.delegations.isEmpty)
        api.extraPart = true
        await manager.refreshAdditionalParts()
        XCTAssertEqual(api.redeems, 2)
        XCTAssertEqual(api.redeemedCodes, [[String(repeating: "B", count: 22)], [String(repeating: "C", count: 22)]])
        XCTAssertEqual(Set(api.recipientPublicKeys).count, 1)
        XCTAssertEqual(app.guests.first?.invite, original.invite)
        await manager.checkAll()
        XCTAssertEqual(app.guests.count, 2)
        XCTAssertEqual(app.receivedDelegations.first?.parts.count, 2)
        XCTAssertEqual(app.receivedDelegations.first?.recipient.privateKey, pair.privateKey)
        await manager.refreshAdditionalParts()
        await manager.checkAll()
        XCTAssertEqual(api.redeems, 2)
        XCTAssertTrue(app.journal.isEmpty)
    }
    func testAdditionalPartStorageFailureNeverPostsAReplacementAndBackgroundStopsPolling() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub()
        let app = AppModel(storage: storage), manager = DelegationInbox(app: app, api: api, automaticUpdates: false)
        api.ready = true
        await manager.inspect(try link().url); await manager.accept()
        let original = app.guests[0].invite
        api.extraPart = true; storage.fail = true
        await manager.refreshAdditionalParts()
        XCTAssertEqual(api.redeems, 1)
        XCTAssertEqual(app.guests[0].invite, original)
        XCTAssertTrue(app.delegations.isEmpty)
        storage.fail = false
        await manager.refreshAdditionalParts(); await manager.checkAll()
        XCTAssertEqual(api.redeems, 2)
        let polling = DelegationInbox(app: app, api: api)
        polling.resume(); polling.suspend(); app.suspend()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(api.redeems, 2)
        XCTAssertEqual(app.guests.count, 2)
    }

    func testDeletingGroupDuringInfoResponseCannotReinstallIt() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub()
        let app = AppModel(storage:storage), manager = DelegationInbox(app:app,api:api,automaticUpdates:false)
        defer { app.suspend() }
        api.ready = true
        await manager.inspect(try link().url); await manager.accept()
        let groupID = try link().id
        api.extraPart = true; api.afterInfo = { app.removeReceivedKeyRecord(groupID) }
        await manager.refreshAdditionalParts()
        XCTAssertTrue(app.guests.isEmpty); XCTAssertTrue(app.receivedDelegations.isEmpty)
        XCTAssertTrue(app.delegations.isEmpty); XCTAssertEqual(api.redeems,1)
    }
    func testMigratedGroupPersistsBaselineBeforeRedeemAndRetainsOriginalSigningKey() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub(), group = try link()
        let recipient = BundleKeySeal.makeRecipient()
        let original = try GuestInvite.parse("https://controller.invalid/key#" + GuestCrypto.base64URL(Data(repeating:13,count:24)) + GuestCrypto.base64URL(Data(repeating:7,count:32)))
        var guest = SavedGuest(invite:original)
        guest.keyGroup = group.id; guest.incomingRecipient = recipient; guest.importedDelegationLink = group
        let receipt = try ReceivedDelegation(importing:group,recipient:recipient,guestIDs:[guest.id])
        storage.state = SavedState(identity:Data(repeating:19,count:32),guests:[guest],receivedDelegations:[receipt])
        let app = AppModel(storage:storage), manager = DelegationInbox(app:app,api:api,automaticUpdates:false)
        defer { app.suspend() }
        api.extraPart = true; api.ready = true; storage.fail = true
        await manager.refreshAdditionalParts()
        XCTAssertEqual(api.redeems,0); XCTAssertNil(app.receivedDelegations.first?.importedBaselineCodes)
        storage.fail = false
        api.beforeRedeem = { pending in
            XCTAssertEqual(storage.state?.receivedDelegations?.first?.importedBaselineCodes,[String(repeating:"B",count:22)])
            XCTAssertEqual(storage.state?.delegations?.first?.recipient.privateKey,recipient.privateKey)
            XCTAssertEqual(pending.parts.map(\.code),[String(repeating:"C",count:22)])
        }
        await manager.refreshAdditionalParts(); await manager.checkAll()
        XCTAssertEqual(api.redeems,1); XCTAssertEqual(app.guests.first?.invite,original)
        XCTAssertEqual(app.receivedDelegations.first?.recipient.privateKey,recipient.privateKey)
        XCTAssertEqual(app.receivedKeyRecords.count,1); XCTAssertEqual(app.guests.count,2)
    }
    func testInitialWelcomeIsQueuedOnceAndLaterPartRetainsGroupLabel() async throws {
        let storage = DelegationStorage(), api = DelegationAPIStub()
        let app = AppModel(storage:storage), manager = DelegationInbox(app:app,api:api,automaticUpdates:false)
        defer { app.suspend() }
        api.ready = true
        api.welcomeCipher = try GuestCrypto.encrypt(key:link().secret,plaintext:JSONSerialization.data(withJSONObject:["from":"Анна","text":"Вход со двора"]))
        await manager.inspect(try link().url); await manager.accept()
        let first = try XCTUnwrap(app.incomingMessages.first)
        XCTAssertEqual(app.receivedKeyRecords.first?.title,"Анна")
        XCTAssertEqual(try MessageManager(app:app).text(first),"Вход со двора")
        XCTAssertTrue(first.deliveryAcknowledged)
        // Simulate a read message evicted from the bounded local queue.
        try app.saveMessages(incoming:[])
        api.extraPart = true
        await manager.refreshAdditionalParts(); await manager.checkAll()
        XCTAssertEqual(app.guests.count,2); XCTAssertEqual(app.receivedKeyRecords.count,1)
        XCTAssertTrue(app.incomingMessages.isEmpty); XCTAssertEqual(app.receivedKeyRecords.first?.title,"Анна")
    }

}
