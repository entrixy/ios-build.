import XCTest
import EntrixyCore
@testable import Entrixy

private final class BackupStorage: StateStorage {
    var state: SavedState?
    var fails = false
    init(_ state: SavedState) { self.state = state }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if fails { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}
private final class BackupOwnerAPI: OwnerTransport {
    var calls: [(String, Bool)] = []
    var failServer: String?
    var beforeClaim: (() -> Void)?
    func register(server: String, accessCode: String) async throws -> OwnerCredentials { throw BackupFailure.invalidPayload }
    func sync(server: String, credentials: OwnerCredentials, fingerprint: String) async throws -> Data { throw BackupFailure.invalidPayload }
    func mutate(server: String, credentials: OwnerCredentials, fingerprint: String, operation: OwnerOperation, body: Data) async throws -> Data {
        XCTAssertEqual(operation, .hostClaim)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let dry = json["dry_run"] as? Int == 1
        calls.append((server, dry))
        if server == failServer { throw URLError(.notConnectedToInternet) }
        if !dry { beforeClaim?() }
        return Data(#"{"ok":1,"claim":"moved"}"#.utf8)
    }
}
private final class BackupGuestMover: GuestMigrationTransport {
    var calls = 0
    var fail = false
    var fingerprints: [(String, String)] = []
    func move(invite: GuestInvite, oldFingerprint: String, newFingerprint: String) async throws {
        calls += 1; fingerprints.append((oldFingerprint, newFingerprint))
        if fail { throw URLError(.networkConnectionLost) }
    }
}

@MainActor
final class BackupTests: XCTestCase {
    private let targetIdentity = Data(repeating: 13, count: 32)
    private func source(guests: Bool = false) throws -> SavedState {
        let credentials = try OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64))
        var a = try OwnerAccount(server: "first.invalid"), b = try OwnerAccount(server: "second.invalid")
        a.credentials = credentials; b.credentials = credentials
        let invite = try GuestInvite.parse("https://guest.invalid/key#" + String(repeating: "A", count: 32) + GuestCrypto.base64URL(Data(repeating: 9, count: 32)))
        return SavedState(identity: Data(repeating: 71, count: 32), guests: guests ? [SavedGuest(invite: invite)] : [], owners: [a, b])
    }
    private func inspect(_ source: SavedState, manager: BackupManager) async throws {
        let bytes = try BackupEnvelope.seal(JSONEncoder().encode(IOSBackupPayload(state: source)), password: "test-password")
        try await manager.inspect(bytes, password: "test-password")
    }
    func testInspectAndFailedPreflightNeverMoveOrReplaceTargetIdentity() async throws {
        let store = BackupStorage(SavedState(identity: targetIdentity, guests: [])), api = BackupOwnerAPI()
        let app = AppModel(storage: store, ownerAPI: api)
        let manager = BackupManager(app: app, guestMover: BackupGuestMover(), refreshAfterRestore: false)
        try await inspect(source(), manager: manager)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertNil(store.state?.pendingRestore)
        api.failServer = "second.invalid"
        await manager.restore()
        XCTAssertEqual(api.calls.count, 2)
        XCTAssertTrue(api.calls.allSatisfy { $0.1 })
        XCTAssertEqual(store.state?.identity, targetIdentity)
        XCTAssertTrue(app.owners.isEmpty)
        XCTAssertNotNil(store.state?.pendingRestore)
    }
    func testPlanSaveFailureSendsNothing() async throws {
        let store = BackupStorage(SavedState(identity: targetIdentity, guests: [])), api = BackupOwnerAPI()
        let app = AppModel(storage: store, ownerAPI: api)
        let manager = BackupManager(app: app, refreshAfterRestore: false)
        try await inspect(source(), manager: manager)
        store.fails = true
        await manager.restore()
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertNil(app.backupPlan())
        XCTAssertFalse(app.ownerBusy)
    }
    func testLostGuestReplyResumesFromDurableOwnerCheckpointsAfterRelaunch() async throws {
        let store = BackupStorage(SavedState(identity: targetIdentity, guests: [])), api = BackupOwnerAPI(), mover = BackupGuestMover()
        let source = try source(guests: true)
        let app = AppModel(storage: store, ownerAPI: api)
        let manager = BackupManager(app: app, guestMover: mover, refreshAfterRestore: false)
        try await inspect(source, manager: manager)
        mover.fail = true
        await manager.restore()
        XCTAssertEqual(app.owners.count, 2)
        XCTAssertEqual(store.state?.pendingRestore?.restoredOwners.count, 2)
        XCTAssertTrue(app.guests.isEmpty)
        let claimCount = api.calls.count
        let relaunched = AppModel(storage: store, ownerAPI: api)
        mover.fail = false
        let resumed = BackupManager(app: relaunched, guestMover: mover, refreshAfterRestore: false)
        await resumed.restore()
        XCTAssertNil(store.state?.pendingRestore)
        XCTAssertEqual(api.calls.count, claimCount)
        XCTAssertEqual(relaunched.guests.count, 1)
        XCTAssertEqual(store.state?.identity, targetIdentity)
        XCTAssertNotEqual(mover.fingerprints[0].0, mover.fingerprints[0].1)
        XCTAssertEqual(mover.fingerprints[0].1, try MigrationFingerprint.ios(identity: targetIdentity, server: "guest.invalid"))
        XCTAssertTrue(relaunched.journal.isEmpty)
    }
    func testClaimAcknowledgementWriteFailureRetainsSourcePlan() async throws {
        let store = BackupStorage(SavedState(identity: targetIdentity, guests: [])), api = BackupOwnerAPI()
        let app = AppModel(storage: store, ownerAPI: api)
        let manager = BackupManager(app: app, refreshAfterRestore: false)
        try await inspect(source(), manager: manager)
        api.beforeClaim = { store.fails = true }
        await manager.restore()
        XCTAssertTrue(app.owners.isEmpty)
        XCTAssertEqual(store.state?.pendingRestore?.payload.owners.count, 2)
        XCTAssertEqual(store.state?.pendingRestore?.restoredOwners.count, 0)
        XCTAssertEqual(api.calls.filter { !$0.1 }.count, 1)
        store.fails = false; api.beforeClaim = nil
        await manager.restore()
        XCTAssertEqual(app.owners.count, 2)
        XCTAssertNil(app.backupPlan())
        XCTAssertEqual(store.state?.identity, targetIdentity)
    }
    func testConflictingOwnerRefusesBeforeMigration() async throws {
        let source = try source()
        var conflict = try OwnerAccount(server: "first.invalid")
        conflict.credentials = source.owners![0].credentials
        let store = BackupStorage(SavedState(identity: targetIdentity, guests: [], owners: [conflict])), api = BackupOwnerAPI()
        let app = AppModel(storage: store, ownerAPI: api)
        let manager = BackupManager(app: app, refreshAfterRestore: false)
        do { try await inspect(source, manager: manager); XCTFail("Different master key must not be overwritten") }
        catch { }
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertNil(manager.preview)
        XCTAssertEqual(app.owners[0].masterKey, conflict.masterKey)
    }
    func testExistingOwnerReceivesAllMissingBackupSecretsAndConflictsStopBeforeClaims() async throws {
        var sourceOwner = try OwnerAccount(server: "first.invalid")
        sourceOwner.credentials = try OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64))
        var first = try OwnerObject(masterKey: sourceOwner.masterKey, label: "Ворота", kind: "call", phone: "+15550000001")
        first.numberID = 7; first.pending = nil; first.available = true
        var second = try OwnerObject(masterKey: sourceOwner.masterKey, label: "Калитка", kind: "call", phone: "+15550000002")
        second.numberID = 8; second.pending = nil; second.available = true
        sourceOwner.objects = [first, second]
        var key = try OwnerIssuedKey(owner: sourceOwner, label: "Друг", numberIDs: [7,8], welcome: "", nativeOnly: false, confirmation: true)
        key.keyID = 17; key.pending = nil; key.state = .active; sourceOwner.issuedKeys = [key]
        var existing = sourceOwner; existing.objects = [first]; existing.issuedKeys = []
        let store = BackupStorage(SavedState(identity: targetIdentity, guests: [], owners: [existing])), api = BackupOwnerAPI()
        let app = AppModel(storage: store, ownerAPI: api)
        let manager = BackupManager(app: app, guestMover: BackupGuestMover(), refreshAfterRestore: false)
        try await inspect(SavedState(identity: Data(repeating: 71, count: 32), guests: [], owners: [sourceOwner]), manager: manager)
        await manager.restore()
        XCTAssertNil(store.state?.pendingRestore)
        XCTAssertEqual(app.owners[0].objects?.count, 2)
        XCTAssertEqual(app.owners[0].issuedKeys?.first?.wrappedSecrets, key.wrappedSecrets)
        XCTAssertEqual(app.owners[0].objects?.first?.wrappedKey, first.wrappedKey)
        XCTAssertEqual(store.state?.identity, targetIdentity)
        XCTAssertEqual(api.calls.count, 2)
        var conflict = sourceOwner
        conflict.issuedKeys![0].grantedAccess?["7"] = try KeyObjectAccess(depth: 1, pool: 3)
        let before = api.calls.count
        do {
            try await inspect(SavedState(identity: Data(repeating: 71, count: 32), guests: [], owners: [conflict]), manager: manager)
            XCTFail("Conflicting owner access must be refused before a server claim")
        } catch {}
        XCTAssertEqual(api.calls.count, before)
        XCTAssertNil(store.state?.pendingRestore)
    }

}
