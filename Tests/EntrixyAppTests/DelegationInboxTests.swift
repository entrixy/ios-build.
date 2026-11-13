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
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data { throw BackupFailure.invalidPayload }
    func delegationInfo(server: String, group: String) async throws -> Data {
        var parts = [["code": String(repeating: "B", count: 22), "state": extraPart ? "redeemed" : "new"]]
        if extraPart { parts.append(["code": String(repeating: "C", count: 22), "state": "new"]) }
        return try JSONSerialization.data(withJSONObject: ["grp": group, "state": "new", "parts": parts])
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

}
