import XCTest
import EntrixyCore
@testable import Entrixy

private final class OwnerMemoryStorage: StateStorage {
    var state: SavedState? = SavedState(identity: Data(repeating: 81, count: 32), guests: [])
    var failing = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if failing { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}

private final class RecordingOwnerAPI: OwnerTransport {
    var registrations = 0
    var syncs = 0
    var mutations = 0
    var loseCreateReply = false
    var rows: [[String: Any]] = []
    var keyRows: [[String: Any]] = []
    var loseKeyReply = false
    var loseKeyEditReply = false
    var loseMessageReply = false
    private(set) var keyMutations = 0
    var beforeMutation: ((OwnerOperation, Data) -> Void)?
    var liveChannel: RecordingOwnerChannel?
    func live(server: String, credentials: OwnerCredentials, fingerprint: String) throws -> OwnerLiveTransport {
        guard let liveChannel else { throw GuestCrypto.Failure.invalidEnvelope }
        return liveChannel
    }
    var registrationHook: (() throws -> Void)?
    var syncHook: (() throws -> Void)?
    var beforeRegister: (() -> Void)?
    var beforeSync: (() -> Void)?
    let credentials = try! OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64))
    func register(server: String, accessCode: String) async throws -> OwnerCredentials {
        registrations += 1
        beforeRegister?()
        try registrationHook?()
        return credentials
    }
    func sync(server: String, credentials: OwnerCredentials, fingerprint: String) async throws -> Data {
        syncs += 1
        beforeSync?()
        XCTAssertEqual(credentials, self.credentials)
        XCTAssertEqual(fingerprint.count, 64)
        try syncHook?()
        return try JSONSerialization.data(withJSONObject: ["numbers": rows, "keys": keyRows])
    }
    func mutate(server: String, credentials: OwnerCredentials, fingerprint: String, operation: OwnerOperation, body: Data) async throws -> Data {
        mutations += 1
        beforeMutation?(operation, body)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        switch operation {
        case .messageSend:
            if loseMessageReply { throw URLError(.networkConnectionLost) }
            return Data(#"{"ok":1}"#.utf8)
        case .hostClaim: return Data(#"{"ok":1,"claim":"moved"}"#.utf8)
        case .keyCreate:
            keyMutations += 1
            guard keyRows.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
            keyRows = [["id": 17, "enabled": 1, "mode": "auto", "sign_pub": json["sign_pub"]!, "number_ids": json["number_ids"]!, "bundle_cipher": json["bundle_cipher"]!, "objects": json["objects"]!]]
            if loseKeyReply { throw URLError(.networkConnectionLost) }
            return Data(#"{"id":17}"#.utf8)
        case .keyMode:
            keyMutations += 1
            keyRows[0]["mode"] = json["mode"]
        case .keyRevoke:
            keyMutations += 1
            let index = keyRows.firstIndex { ($0["id"] as? Int) == (json["id"] as? Int) } ?? 0
            keyRows[index]["enabled"] = 0
        case .keyEdit:
            keyMutations += 1
            let index = keyRows.firstIndex { ($0["id"] as? Int) == (json["id"] as? Int) } ?? 0
            keyRows[index]["bundle_cipher"] = json["bundle_cipher"]
            keyRows[index]["number_ids"] = json["number_ids"]
            if let objects = json["objects"] { keyRows[index]["objects"] = objects }
            if let cipher = json["key_cipher"] { keyRows[index]["key_cipher"] = cipher; keyRows[index]["needs_bundle"] = 0 }
            if loseKeyEditReply { throw URLError(.networkConnectionLost) }
        case .claim: return Data(#"{"device_id":9}"#.utf8)
        case .create:
            rows = [["id": 7, "type": json["type"]!, "data_cipher": json["data_cipher"]!, "data_cipher_revision": 100]]
            if loseCreateReply { throw URLError(.networkConnectionLost) }
            return Data(#"{"id":7}"#.utf8)
        case .update:
            rows[0]["data_cipher"] = json["data_cipher"]
            rows[0]["data_cipher_revision"] = 101
        case .delete: rows = []
        }
        return Data(#"{"ok":true}"#.utf8)
    }
}

private final class RecordingOwnerChannel: OwnerLiveTransport {
    let frames: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var writes: [[String: Any]] = []
    var onWrite: (([String: Any]) throws -> Void)?
    init() {
        var output: AsyncThrowingStream<Data, Error>.Continuation!
        frames = AsyncThrowingStream { output = $0 }
        continuation = output
        emit(["type": "host_ok"])
    }
    func emit(_ json: [String: Any]) { continuation.yield(try! JSONSerialization.data(withJSONObject: json)) }
    func sendAction(_ frame: Data) async throws {
        let json = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        writes.append(json)
        try onWrite?(json)
    }
    func close() { continuation.finish() }
}

final class OwnerAccountTests: XCTestCase {
    @MainActor func testRegistrationPersistsBeforeNetworkAndCredentialsBeforeSync() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let originalIdentity = storage.state!.identity
        api.beforeRegister = {
            XCTAssertEqual(storage.state?.owners?.count, 1)
            XCTAssertTrue(storage.state?.owners?.first?.registrationPending == true)
        }
        api.beforeSync = { XCTAssertEqual(storage.state?.owners?.first?.credentials, api.credentials) }
        let model = AppModel(storage: storage, ownerAPI: api)
        let added = await model.addOwner(server: "https://OWNER.invalid/", accessCode: "public-test")
        XCTAssertTrue(added)
        XCTAssertEqual(api.registrations, 1)
        XCTAssertEqual(api.syncs, 1)
        XCTAssertEqual(model.ownerSnapshots["owner.invalid"]?.objectCount, 0)
        XCTAssertEqual(storage.state?.identity, originalIdentity)
        XCTAssertTrue(model.journal.isEmpty)
        // Existing guest writes must never discard the owner access.
        model.recordAction(JournalEntry(who: "Я", what: "Проверка", actionKey: "test-owner-persistence"))
        XCTAssertEqual(storage.state?.owners?.first?.credentials, api.credentials)
        let duplicate = await model.addOwner(server: "owner.invalid", accessCode: "")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(api.registrations, 1)
    }

    @MainActor func testLostReplyAndRelaunchNeverRegisterAgain() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        api.registrationHook = { throw URLError(.networkConnectionLost) }
        let first = AppModel(storage: storage, ownerAPI: api)
        let result = await first.addOwner(server: "owner.invalid", accessCode: "")
        XCTAssertFalse(result)
        XCTAssertTrue(storage.state!.owners!.first!.registrationPending)
        let second = AppModel(storage: storage, ownerAPI: api)
        await second.refreshOwners()
        let duplicate = await second.addOwner(server: "owner.invalid", accessCode: "")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(api.registrations, 1)
        XCTAssertEqual(api.syncs, 0)
        XCTAssertEqual(second.owners.first?.masterKey, first.owners.first?.masterKey)
    }

    @MainActor func testStorageFailurePreventsRegistration() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        storage.failing = true
        let added = await model.addOwner(server: "owner.invalid", accessCode: "")
        XCTAssertFalse(added)
        XCTAssertEqual(api.registrations, 0)
        XCTAssertTrue(model.owners.isEmpty)
    }

    @MainActor func testCredentialSaveFailureRetriesOnlyStorage() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        api.registrationHook = { storage.failing = true }
        let added = await model.addOwner(server: "owner.invalid", accessCode: "")
        XCTAssertFalse(added)
        XCTAssertTrue(model.canSaveOwnerAccess("owner.invalid"))
        XCTAssertEqual(api.syncs, 0)
        storage.failing = false
        await model.retrySavingOwnerAccess("owner.invalid")
        XCTAssertEqual(api.registrations, 1)
        XCTAssertEqual(api.syncs, 1)
        XCTAssertEqual(storage.state?.owners?.first?.credentials, api.credentials)
        XCTAssertFalse(model.canSaveOwnerAccess("owner.invalid"))
    }

    @MainActor func testSyncFailurePreservesAccountAndLastSnapshot() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        let added = await model.addOwner(server: "owner.invalid", accessCode: "")
        XCTAssertTrue(added)
        let account = model.owners.first
        api.syncHook = { throw URLError(.notConnectedToInternet) }
        await model.refreshOwners()
        XCTAssertEqual(model.owners.first, account)
        XCTAssertEqual(model.ownerSnapshots["owner.invalid"]?.objectCount, 0)
        XCTAssertNotNil(model.ownerMessages["owner.invalid"])
        XCTAssertEqual(api.registrations, 1)
        XCTAssertTrue(model.journal.isEmpty)
    }
    @MainActor func testControllerClaimCreateRenameAndDeletePersistBeforeEveryRequest() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        api.beforeMutation = { operation, body in
            let object = storage.state!.owners!.first!.objects!.first!
            XCTAssertEqual(object.pending, operation)
            XCTAssertTrue(object.sent)
            XCTAssertEqual(try? object.request(), body)
        }
        let created = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "device", phone: "", url: "", secret: "", claimCode: "TEST1234")
        XCTAssertTrue(created)
        XCTAssertEqual(api.mutations, 2)
        let object = try XCTUnwrap(model.owners.first?.objects?.first)
        XCTAssertEqual(object.numberID, 7)
        XCTAssertEqual(object.revision, 100)
        let renamed = await model.renameOwnerObject(server: "owner.invalid", objectID: object.id, label: "Новые ворота")
        XCTAssertTrue(renamed)
        XCTAssertEqual(api.mutations, 3)
        XCTAssertEqual(try model.owners[0].objects![0].metadata(masterKey: model.owners[0].masterKey)["label"] as? String, "Новые ворота")
        await model.deleteOwnerObject(server: "owner.invalid", objectID: object.id)
        XCTAssertEqual(api.mutations, 4)
        XCTAssertTrue(model.owners[0].objects!.isEmpty)
        XCTAssertTrue(model.journal.isEmpty)
    }

    @MainActor func testLostObjectReplyReconcilesAcrossLaunchWithoutNewMutation() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let first = AppModel(storage: storage, ownerAPI: api)
        _ = await first.addOwner(server: "owner.invalid", accessCode: "")
        api.loseCreateReply = true
        let created = await first.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "call", phone: "+79990000000", url: "", secret: "", claimCode: "")
        XCTAssertFalse(created)
        XCTAssertEqual(api.mutations, 1)
        XCTAssertTrue(storage.state!.owners![0].objects![0].sent)
        storage.state = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(storage.state!))
        let second = AppModel(storage: storage, ownerAPI: api)
        await second.refreshOwners()
        XCTAssertEqual(api.mutations, 1)
        XCTAssertNil(second.owners[0].objects![0].pending)
        XCTAssertEqual(second.owners[0].objects![0].numberID, 7)
        XCTAssertEqual(second.owners[0].objects![0].wrappedKey, first.owners[0].objects![0].wrappedKey)
    }

    @MainActor func testObjectSaveFailureSendsNoMutation() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        storage.failing = true
        let created = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "call", phone: "+79990000000", url: "", secret: "", claimCode: "")
        XCTAssertFalse(created)
        XCTAssertEqual(api.mutations, 0)
        XCTAssertTrue((model.owners[0].objects ?? []).isEmpty)
    }

    @MainActor func testClaimReplySaveFailureRetainsDeviceWithoutRepeatingClaim() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        api.beforeMutation = { operation, _ in if operation == .claim { storage.failing = true } }
        let created = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "device", phone: "", url: "", secret: "", claimCode: "TEST1234")
        XCTAssertFalse(created)
        XCTAssertEqual(api.mutations, 1)
        let id = try XCTUnwrap(model.owners.first?.objects?.first?.id)
        XCTAssertTrue(model.canSaveOwnerObjectResult(id))
        storage.failing = false
        await model.retrySavingOwnerObjectResult(server: "owner.invalid", objectID: id)
        XCTAssertEqual(api.mutations, 2) // claim once, then number_add once.
        XCTAssertEqual(model.owners[0].objects![0].numberID, 7)
        XCTAssertNil(model.owners[0].objects![0].pending)
        XCTAssertFalse(model.canSaveOwnerObjectResult(id))
    }

    @MainActor func testGuestIssueSharePauseResumeRevokeUsePersistedKeyAndNoJournalFabrication() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "owner-private", claimCode: "")
        api.beforeMutation = { operation, body in
            let owner = storage.state!.owners![0]
            let key = owner.issuedKeys![0]
            XCTAssertEqual(key.pending, operation)
            XCTAssertTrue(key.sent)
            XCTAssertEqual(try? key.request(masterKey: owner.masterKey), body)
        }
        let issued = await model.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "Здравствуйте", nativeOnly: false, confirmation: true)
        XCTAssertTrue(issued)
        let id = try XCTUnwrap(model.owners[0].issuedKeys?.first?.id)
        let owner = model.owners[0]
        let invite = try GuestInvite.parse(owner.issuedKeys![0].link(server: owner.server, masterKey: owner.masterKey).absoluteString)
        XCTAssertEqual(invite.server, "owner.invalid")
        await model.setOwnerKeyMode(server: owner.server, keyID: id, paused: true)
        XCTAssertEqual(model.owners[0].issuedKeys![0].state, .paused)
        await model.setOwnerKeyMode(server: owner.server, keyID: id, paused: false)
        XCTAssertEqual(model.owners[0].issuedKeys![0].state, .active)
        await model.revokeOwnerKey(server: owner.server, keyID: id)
        XCTAssertEqual(model.owners[0].issuedKeys![0].state, .revoked)
        XCTAssertThrowsError(try model.owners[0].issuedKeys![0].link(server: owner.server, masterKey: owner.masterKey))
        XCTAssertEqual(api.keyMutations, 4)
        XCTAssertTrue(model.journal.isEmpty)
    }

    @MainActor func testLostKeyCreationReplyReconcilesAcrossLaunchWithoutRegeneration() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let first = AppModel(storage: storage, ownerAPI: api)
        _ = await first.addOwner(server: "owner.invalid", accessCode: "")
        _ = await first.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "owner-private", claimCode: "")
        api.loseKeyReply = true
        let issued = await first.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        XCTAssertFalse(issued)
        let old = try XCTUnwrap(first.owners[0].issuedKeys?.first)
        XCTAssertTrue(old.sent)
        storage.state = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(storage.state!))
        let second = AppModel(storage: storage, ownerAPI: api)
        await second.refreshOwners()
        XCTAssertEqual(api.keyMutations, 1)
        XCTAssertEqual(second.owners[0].issuedKeys![0].wrappedSecrets, old.wrappedSecrets)
        XCTAssertEqual(second.owners[0].issuedKeys![0].state, .active)
        XCTAssertNil(second.owners[0].issuedKeys![0].pending)
    }

    @MainActor func testReceivedKeyIDCanBeSavedWithoutAnotherCreateAfterStorageFailure() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "owner-private", claimCode: "")
        api.beforeMutation = { operation, _ in if operation == .keyCreate { storage.failing = true } }
        let issued = await model.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        XCTAssertFalse(issued)
        let id = try XCTUnwrap(model.owners[0].issuedKeys?.first?.id)
        XCTAssertTrue(model.canSaveOwnerKeyResult(id))
        storage.failing = false
        await model.retrySavingOwnerKeyResult(server: "owner.invalid", keyID: id)
        XCTAssertEqual(api.keyMutations, 1)
        XCTAssertEqual(model.owners[0].issuedKeys![0].keyID, 17)
        XCTAssertEqual(model.owners[0].issuedKeys![0].state, .active)
    }

    @MainActor private func waitForOwner(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for owner state")
    }

    @MainActor func testOwnerCommandPersistsBeforeWireAndUsesOnlyMatchingActualResult() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "private", claimCode: "")
        let object = try XCTUnwrap(model.owners[0].objects?.first)
        let channel = RecordingOwnerChannel(); api.liveChannel = channel
        channel.onWrite = { frame in
            XCTAssertEqual(storage.state?.journal?.first?.result, "Результат не получен")
            XCTAssertEqual(frame["type"] as? String, "host_self_webhook")
            channel.emit(["type": "device_status", "number_id": 99, "call_id": "owner-test", "message": "Wrong object", "final": true])
            // A fast webhook may finish before its device_sent acknowledgement.
            channel.emit(["type": "device_status", "number_id": 7, "call_id": "owner-test", "message": "Actual recording response", "level": "success", "final": true])
            channel.emit(["type": "device_sent", "number_id": 7, "call_id": "owner-test"])
        }
        let control = OwnerControlModel(app: model, dialer: { _ in XCTFail("No dialer expected"); return false })
        defer { control.suspend() }
        control.resume()
        try await waitForOwner { control.connections["owner.invalid"] == .connected }
        await control.execute(server: "owner.invalid", objectID: object.id, action: .open)
        try await waitForOwner { control.messages[object.id] == "Actual recording response" }
        XCTAssertEqual(channel.writes.count, 1)
        XCTAssertEqual(model.journal.count, 1)
        XCTAssertEqual(model.journal.first?.result, "Actual recording response")
    }

    @MainActor func testBackgroundCancelsOwnerCommandWithoutReplay() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "private", claimCode: "")
        let channel = RecordingOwnerChannel(); api.liveChannel = channel
        let control = OwnerControlModel(app: model)
        defer { control.suspend() }
        control.resume()
        try await waitForOwner { control.connections["owner.invalid"] == .connected }
        await control.execute(server: "owner.invalid", objectID: model.owners[0].objects![0].id, action: .open)
        control.suspend()
        channel.emit(["type": "device_status", "number_id": 7, "call_id": "late", "message": "Must be ignored", "final": true])
        api.liveChannel = RecordingOwnerChannel()
        control.resume()
        try await waitForOwner { control.connections["owner.invalid"] == .connected }
        XCTAssertEqual(channel.writes.count, 1)
        XCTAssertEqual(api.liveChannel?.writes.count, 0)
        XCTAssertEqual(model.journal.first?.result, "Результат не получен")
    }

    @MainActor func testSignedGuestPhoneRequestNeedsExplicitTapAndReplayIsDurablyRejected() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "call", phone: "+79990000000", url: "", secret: "", claimCode: "")
        _ = await model.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        let owner = model.owners[0], pair = try owner.issuedKeys![0].secrets(masterKey: owner.masterKey)
        let signed = try GuestPress.frame(userKey: pair.userKey, host: owner.server, numberID: 7, wireAction: "")
        let press = (try JSONSerialization.jsonObject(with: signed) as! [String: Any])["press"]!
        let request: [String: Any] = ["type": "do_call", "call_id": "guest-call", "number_id": 7, "user_key_id": 17, "press": press]
        let channel = RecordingOwnerChannel(); api.liveChannel = channel
        var dialed = 0
        let control = OwnerControlModel(app: model, dialer: { _ in dialed += 1; return true })
        defer { control.suspend() }
        control.resume()
        try await waitForOwner { control.connections[owner.server] == .connected }
        channel.emit(request); channel.emit(request)
        try await waitForOwner { control.phoneRequests.count == 1 }
        XCTAssertEqual(dialed, 0)
        XCTAssertTrue(model.journal.isEmpty)
        control.suspend()
        let restored = AppModel(storage: storage, ownerAPI: api)
        let restoredChannel = RecordingOwnerChannel(); api.liveChannel = restoredChannel
        let second = OwnerControlModel(app: restored, dialer: { _ in dialed += 1; return true })
        defer { second.suspend() }
        second.resume()
        try await waitForOwner { second.connections[owner.server] == .connected }
        restoredChannel.emit(request)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(second.phoneRequests.isEmpty)
        XCTAssertEqual(dialed, 0)
    }

    @MainActor func testOwnerPhoneHandoffDoesNotClaimACompletedCall() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "call", phone: "+79990000000", url: "", secret: "", claimCode: "")
        var dialed: URL?
        let control = OwnerControlModel(app: model, dialer: { url in
            XCTAssertEqual(storage.state?.journal?.first?.result, "Результат звонка не подтверждён")
            dialed = url; return true
        })
        defer { control.suspend() }
        control.resume()
        await control.dial(server: "owner.invalid", objectID: model.owners[0].objects![0].id)
        XCTAssertEqual(dialed?.scheme, "tel")
        XCTAssertEqual(model.journal.first?.result, "Передано приложению «Телефон»")
        XCTAssertEqual(model.journal.first?.level, "info")
    }

    @MainActor func testGuestKeyEditAndLostReplyKeepTheExistingInvitation() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "private", claimCode: "")
        _ = await model.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        let owner = model.owners[0], key = owner.issuedKeys![0]
        let link = try key.link(server: owner.server, masterKey: owner.masterKey)
        api.loseKeyEditReply = true
        let edited = await model.editOwnerKey(server: owner.server, keyID: key.id, label: "Новое имя", numberIDs: [7], welcome: "Новое приветствие", confirmation: nil)
        XCTAssertFalse(edited)
        XCTAssertEqual(api.keyMutations, 2)
        XCTAssertEqual(model.owners[0].issuedKeys![0].pending, .keyEdit)
        await model.refreshOwners()
        XCTAssertNil(model.owners[0].issuedKeys![0].pending)
        XCTAssertEqual(model.owners[0].issuedKeys![0].label, "Новое имя")
        XCTAssertEqual(try model.owners[0].issuedKeys![0].link(server: owner.server, masterKey: owner.masterKey), link)
        XCTAssertEqual(api.keyMutations, 2)
        XCTAssertTrue(model.journal.isEmpty)
    }

    @MainActor func testExplicitDelegationLimitsPersistBeforeWireAndSurviveLostEditReply() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let model = AppModel(storage: storage, ownerAPI: api)
        _ = await model.addOwner(server: "owner.invalid", accessCode: "")
        _ = await model.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "private", claimCode: "")
        let settings = try KeyObjectAccess(depth: 2, pool: 8)
        api.beforeMutation = { operation, _ in
            if operation == .keyCreate { XCTAssertEqual(storage.state?.owners?[0].issuedKeys?[0].requestedAccess?["7"], settings) }
        }
        let created = await model.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true, access: [7: settings])
        XCTAssertTrue(created)
        let key = model.owners[0].issuedKeys![0]
        let tighter = try KeyObjectAccess(depth: 0, pool: 1)
        api.loseKeyEditReply = true
        _ = await model.editOwnerKey(server: "owner.invalid", keyID: key.id, label: key.label, numberIDs: [7], welcome: "", confirmation: nil, access: [7: tighter])
        XCTAssertEqual(model.owners[0].issuedKeys![0].grantedAccess?["7"], settings)
        await model.refreshOwners()
        XCTAssertEqual(model.owners[0].issuedKeys![0].grantedAccess?["7"], tighter)
        XCTAssertEqual(api.keyMutations, 2)
        XCTAssertTrue(model.journal.isEmpty)
    }

    @MainActor func testOwnerDelegatedBundlePersistsBeforeUploadAndRecoversLostReplyWithoutReissue() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let app = AppModel(storage: storage, ownerAPI: api)
        _ = await app.addOwner(server: "owner.invalid", accessCode: "")
        _ = await app.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "private", claimCode: "")
        _ = await app.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false,
            confirmation: true, access: [7: try KeyObjectAccess(depth: 2, pool: 8)])
        let owner = app.owners[0], root = owner.issuedKeys![0], pair = try root.secrets(masterKey: owner.masterKey)
        let recipient = BundleKeySeal.makeRecipient(), user = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3"
        let pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: user).publicKey.rawRepresentation)
        api.keyRows.append(["id": 18, "parent_key_id": 17, "enabled": 1, "mode": "auto", "number_ids": [7], "ble_ids": [Int](),
            "sign_pub": pub, "guest_pub": recipient.publicKey,
            "vouch_sig": try DelegationProof.vouch(userKey: pair.userKey, server: owner.server, childID: 18, signPublic: pub, guestPublic: recipient.publicKey),
            "objects": [try KeyObjectAccess(depth: 1, pool: 3).json(id: 7)], "needs_bundle": 1])
        await app.refreshOwners()
        let prepared = try XCTUnwrap(app.owners[0].delegatedKeys?.first)
        XCTAssertEqual(api.keyMutations, 1)
        api.beforeMutation = { operation, body in
            if operation == .keyEdit {
                XCTAssertEqual(storage.state?.owners?[0].delegatedKeys?[0].sent, true)
                XCTAssertEqual(storage.state?.owners?[0].delegatedKeys?[0].bundleCipher, prepared.bundleCipher)
                XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(user))
            }
        }
        api.loseKeyEditReply = true
        await app.approveDelegatedKey(server: owner.server, keyID: prepared.id)
        XCTAssertEqual(app.owners[0].delegatedKeys?[0].state, .awaiting)
        XCTAssertEqual(app.owners[0].delegatedKeys?[0].sent, true)
        let relaunched = AppModel(storage: storage, ownerAPI: api)
        await relaunched.refreshOwners()
        let confirmed = try XCTUnwrap(relaunched.owners[0].delegatedKeys?.first)
        XCTAssertEqual(confirmed.state, .ready)
        XCTAssertEqual(confirmed.bundleCipher, prepared.bundleCipher)
        XCTAssertEqual(confirmed.guestID, prepared.guestID)
        XCTAssertEqual(api.keyMutations, 2)
        XCTAssertEqual(try BundleKeySeal.open(confirmed.keyCipher, recipient: recipient).count, 32)
        api.loseKeyEditReply = false
        await relaunched.revokeDelegatedKey(server: owner.server, keyID: prepared.id)
        XCTAssertEqual(relaunched.owners[0].delegatedKeys?[0].state, .revoked)
        XCTAssertEqual(api.keyMutations, 3)
        XCTAssertNil(try relaunched.owners[0].authorizedGuest(keyID: 18, numberID: 7))
        XCTAssertTrue(relaunched.journal.isEmpty)
    }

    @MainActor func testOwnerMessageIsSavedBeforeWireAndAnAcceptedReplyNeverClaimsRead() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let app = AppModel(storage: storage, ownerAPI: api)
        _ = await app.addOwner(server: "owner.invalid", accessCode: "")
        _ = await app.createOwnerObject(server: "owner.invalid", label: "Ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "private", claimCode: "")
        _ = await app.createOwnerKey(server: "owner.invalid", label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        let owner = app.owners[0], key = owner.issuedKeys![0], bundleKey = try key.secrets(masterKey: owner.masterKey).bundleKey
        api.beforeMutation = { operation, bytes in
            if operation == .messageSend {
                XCTAssertEqual(storage.state?.outgoingMessages?.first?.state, .sending)
                let row = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                let cipher = row["cipher"] as! String
                XCTAssertEqual(cipher, storage.state?.outgoingMessages?.first?.cipher)
                XCTAssertEqual(try? GuestMessageCrypto.open(cipher, bundleKey: bundleKey), storage.state?.outgoingMessages?.first?.text)
            }
        }
        let manager = MessageManager(app: app)
        let sent = await manager.send("Тестовое сообщение", target: .owner(server: owner.server, keyID: key.id))
        XCTAssertTrue(sent)
        XCTAssertEqual(app.outgoingMessages.first?.state, .accepted)
        api.loseMessageReply = true
        let unknown = await manager.send("Тест без ответа", target: .owner(server: owner.server, keyID: key.id))
        XCTAssertFalse(unknown)
        XCTAssertEqual(app.outgoingMessages.first?.state, .uncertain)
        XCTAssertEqual(app.outgoingMessages.count, 2)
        XCTAssertTrue(app.journal.isEmpty)
    }

}

extension OwnerAccountTests {
    @MainActor func testBLEPauseResumeRenewRevokeAndDeleteKeepDurableDecisionsAndSecrets() async throws {
        let storage = OwnerMemoryStorage(), api = RecordingOwnerAPI()
        let app = AppModel(storage: storage, ownerAPI: api)
        let added = await app.addOwner(server: "https://owner.invalid", accessCode: "")
        XCTAssertTrue(added)
        let owner = try XCTUnwrap(app.owners.first)
        let peer = BLECrypto.makePair()
        var pairing = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "BLE-ворота")
        try pairing.markSent()
        let secret = try pairing.secret(masterKey: owner.masterKey)
        let head = Data([123,0,0,0,1,0,0,0])
        let signed = try BLECrypto.ownerFire(ownerSecret: secret, nonce: head)
        try pairing.confirm(advertisement: head + signed.dropFirst(8).prefix(8), masterKey: owner.masterKey)
        try app.saveBLEPairing(pairing, server: "owner.invalid")
        let registered = await app.registerPairedBLE(server: "owner.invalid", pairingID: pairing.id)
        XCTAssertTrue(registered)
        let issued = await app.createOwnerKey(server: "owner.invalid", label: "Гость", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
        XCTAssertTrue(issued)
        let key = try XCTUnwrap(app.owners.first?.issuedKeys?.first)
        let originalLink = try key.link(server: "owner.invalid", masterKey: owner.masterKey)
        api.beforeMutation = { operation, _ in
            if operation == .keyMode {
                let state = storage.state!.owners!.first!
                XCTAssertEqual(state.bleRevocations?.first?.revoked, true)
                XCTAssertEqual(state.issuedKeys?.first?.pending, .keyMode)
            }
        }
        await app.setOwnerKeyMode(server: "owner.invalid", keyID: key.id, paused: true)
        XCTAssertEqual(app.owners[0].issuedKeys?.first?.state, .paused)
        let deny = try XCTUnwrap(app.owners[0].bleRevocations?.first)
        XCTAssertTrue(deny.revoked); XCTAssertTrue(try deny.verify(ownerSecret: secret))
        api.beforeMutation = { operation, _ in
            if operation == .keyMode {
                XCTAssertTrue(storage.state?.owners?.first?.bleRestorePending?.contains(key.id) == true)
                XCTAssertEqual(storage.state?.owners?.first?.bleRevocations?.first?.revoked, true)
            }
        }
        await app.setOwnerKeyMode(server: "owner.invalid", keyID: key.id, paused: false)
        let allow = try XCTUnwrap(app.owners[0].bleRevocations?.first)
        XCTAssertFalse(allow.revoked); XCTAssertGreaterThan(allow.version, deny.version)
        XCTAssertTrue(app.owners[0].bleRestorePending?.isEmpty == true)
        XCTAssertEqual(app.owners[0].issuedKeys?.first?.state, .active)
        api.beforeMutation = nil; api.loseKeyEditReply = true
        let mutationsBefore = api.keyMutations
        await app.renewOwnerBLEKey(server: "owner.invalid", keyID: key.id)
        let pending = try XCTUnwrap(storage.state?.owners?.first?.issuedKeys?.first)
        XCTAssertEqual(pending.pending, .keyEdit); XCTAssertTrue(pending.sent)
        let exactCipher = pending.bundleCipher
        let restored = AppModel(storage: storage, ownerAPI: api)
        await restored.refreshOwners()
        XCTAssertEqual(api.keyMutations, mutationsBefore + 1)
        XCTAssertEqual(restored.owners[0].issuedKeys?.first?.bundleCipher, exactCipher)
        XCTAssertNil(restored.owners[0].issuedKeys?.first?.pending)
        XCTAssertEqual(try restored.owners[0].issuedKeys![0].link(server: "owner.invalid", masterKey: owner.masterKey), originalLink)
        api.beforeMutation = { operation, _ in
            if operation == .keyRevoke { XCTAssertEqual(storage.state?.owners?.first?.bleRevocations?.first?.revoked, true) }
        }
        await restored.revokeOwnerKey(server: "owner.invalid", keyID: key.id)
        XCTAssertEqual(restored.owners[0].issuedKeys?.first?.state, .revoked)
        XCTAssertGreaterThan(try XCTUnwrap(restored.owners[0].bleRevocations?.first?.version), allow.version)
        let objectID = try XCTUnwrap(restored.owners[0].objects?.first?.id)
        await restored.deleteOwnerObject(server: "owner.invalid", objectID: objectID)
        XCTAssertTrue(restored.owners[0].objects?.isEmpty == true)
        XCTAssertEqual(restored.owners[0].bleArchivedObjects?.count, 1)
        let wrapped = try XCTUnwrap(restored.owners[0].bleArchivedObjects?.first?.wrappedBLESecret)
        XCTAssertEqual(try GuestCrypto.decrypt(key: owner.masterKey, envelope: wrapped), secret)
        XCTAssertNil(restored.owners[0].blePairings?.first?.objectID)
        XCTAssertTrue(restored.journal.isEmpty)
    }
}
