import XCTest
import EntrixyCore
@testable import Entrixy

private final class ResetStorage: StateStorage {
    var state: SavedState?
    var failRead = false
    var failWrite = false
    var writes = 0
    init(_ state: SavedState) { self.state = state }
    func load() throws -> SavedState? {
        if failRead { throw KeychainStore.Failure(status:-1) }
        return state
    }
    func save(_ state: SavedState) throws {
        if failWrite { throw KeychainStore.Failure(status:-1) }
        self.state = state; writes += 1
    }
}

@MainActor final class LocalStateResetTests: XCTestCase {
    func testCorruptResetMarkerCannotEraseFilesWhileProtectedCredentialsStillExist() throws {
        var state = try source(); state.pendingLocalReset = true
        let store = ResetStorage(state), session = LocalStateSession(store)
        XCTAssertThrowsError(try session.load())
        var cleanupCalls = 0
        let app = AppModel(storage:store,resetCleanup:{ _ in cleanupCalls += 1 }); defer { app.suspend() }
        XCTAssertFalse(app.storageReady); XCTAssertFalse(app.localDataErased)
        XCTAssertEqual(cleanupCalls,0); XCTAssertEqual(store.writes,0)
        XCTAssertEqual(store.state?.identity,state.identity)
        XCTAssertEqual(store.state?.guests.map(\.id),state.guests.map(\.id))
        XCTAssertEqual(store.state?.owners?.first?.credentials,state.owners?.first?.credentials)
    }
    private func source() throws -> SavedState {
        let invite = try GuestInvite.parse("https://guest.invalid/key#" + String(repeating:"A",count:32) + GuestCrypto.base64URL(Data(repeating:9,count:32)))
        var owner = try OwnerAccount(server:"owner.invalid")
        owner.credentials = try OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        return SavedState(identity:Data(repeating:7,count:32),guests:[SavedGuest(invite:invite)],owners:[owner],appLockEnabled:true)
    }
    func testFailedReadOrWritePreservesCredentialsAndDoesNotRetireTheSession() throws {
        let original = try source(), store = ResetStorage(original), session = LocalStateSession(store)
        _ = try session.load()
        store.failRead = true
        XCTAssertThrowsError(try session.erase(confirmedIdentity:original.identity))
        store.failRead = false; store.failWrite = true
        XCTAssertThrowsError(try session.erase(confirmedIdentity:original.identity))
        XCTAssertEqual(store.state?.identity,original.identity)
        XCTAssertEqual(store.state?.guests.map(\.id),original.guests.map(\.id))
        XCTAssertEqual(store.state?.owners?.first?.credentials,original.owners?.first?.credentials)
        XCTAssertNil(store.state?.pendingLocalReset); XCTAssertEqual(store.writes,0)
        store.failWrite = false
        try session.save(original)
        XCTAssertEqual(try session.load()?.identity,original.identity)
    }
    func testResetIsOneAtomicEmptyReplacementAndAllOldSessionsRejectDelayedWrites() throws {
        let original = try source(), store = ResetStorage(original)
        let first = LocalStateSession(store), stale = LocalStateSession(store)
        _ = try first.load(); _ = try stale.load()
        XCTAssertThrowsError(try first.erase(confirmedIdentity:Data(repeating:8,count:32)))
        XCTAssertEqual(store.writes,0)
        try first.erase(confirmedIdentity:original.identity)
        let replacement = try XCTUnwrap(store.state)
        XCTAssertNotEqual(replacement.identity,original.identity); XCTAssertEqual(replacement.identity.count,32)
        XCTAssertEqual(store.writes,1); XCTAssertEqual(replacement.pendingLocalReset,true)
        // Exactly the new identity, empty keys and the durable cleanup marker;
        // no credentials, settings, journal, pending transfers or PIN survive.
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(replacement)) as? [String:Any])
        XCTAssertEqual(Set(fields.keys),Set(["identity","guests","pendingLocalReset"]))
        XCTAssertThrowsError(try first.save(original)); XCTAssertThrowsError(try stale.save(original))
        XCTAssertThrowsError(try first.load())
        try first.finishCleanup()
        XCTAssertNil(store.state?.pendingLocalReset)
        XCTAssertThrowsError(try first.save(original)); XCTAssertThrowsError(try stale.save(original))
        XCTAssertEqual(store.state?.identity,replacement.identity)
        let fresh = LocalStateSession(store)
        var newState = try XCTUnwrap(fresh.load()); newState.appLockEnabled = false
        try fresh.save(newState)
        XCTAssertEqual(store.state?.identity,replacement.identity)
    }
    func testCleanupMarkerSurvivesFailedWriteAndCanBeFinishedAfterRelaunch() throws {
        let original = try source(), store = ResetStorage(original), session = LocalStateSession(store)
        try session.erase(confirmedIdentity:original.identity)
        let replacement = try XCTUnwrap(store.state?.identity)
        store.failWrite = true
        XCTAssertThrowsError(try session.finishCleanup())
        XCTAssertEqual(store.state?.pendingLocalReset,true)
        store.failWrite = false
        let relaunched = LocalStateSession(store); _ = try relaunched.load()
        try relaunched.finishCleanup()
        XCTAssertNil(store.state?.pendingLocalReset); XCTAssertEqual(store.state?.identity,replacement)
    }
    func testModelRequiresExactConfirmationAndFailedWriteRetainsWorkingPIN() async throws {
        let store = ResetStorage(SavedState(identity:Data(repeating:7,count:32),guests:[]))
        var cleanupCalls = 0
        let app = AppModel(storage:store,resetCleanup:{ _ in cleanupCalls += 1 }); defer { app.suspend() }
        try await app.setActionCode("1234")
        _ = try await app.configureEntryLock(enabled:true,biometric:false,code:"")
        let writes = store.writes, oldVerifier = store.state?.actionCode?.verifier
        XCTAssertFalse(app.eraseLocalData(confirmation:"reset")); XCTAssertFalse(app.eraseLocalData(confirmation:""))
        XCTAssertEqual(store.writes,writes); XCTAssertEqual(cleanupCalls,0)
        store.failWrite = true
        XCTAssertFalse(app.eraseLocalData(confirmation:"RESET"))
        XCTAssertTrue(app.storageReady); XCTAssertFalse(app.localDataErased)
        XCTAssertEqual(store.state?.actionCode?.verifier,oldVerifier); XCTAssertEqual(cleanupCalls,0)
        store.failWrite = false
        let relaunched = AppModel(storage:store,resetCleanup:{ _ in cleanupCalls += 1 }); defer { relaunched.suspend() }
        XCTAssertTrue(relaunched.appLocked)
        let unlocked = try await relaunched.unlockApplication(code:"1234")
        XCTAssertTrue(unlocked); XCTAssertEqual(cleanupCalls,0)
    }
    func testCleanupFailureKeepsModelRetiredUntilRetryAndNewModelHasNoOldAccess() async throws {
        let store = ResetStorage(SavedState(identity:Data(repeating:7,count:32),guests:[]))
        var failCleanup = true, calls = 0
        let app = AppModel(storage:store,resetCleanup:{ _ in
            calls += 1; if failCleanup { throw KeychainStore.Failure(status:-1) }
        }); defer { app.suspend() }
        try await app.setActionCode("1234")
        XCTAssertFalse(app.eraseLocalData(confirmation:"RESET"))
        XCTAssertTrue(app.localDataErased); XCTAssertTrue(app.localResetCleanupPending)
        XCTAssertFalse(app.storageReady); XCTAssertFalse(app.canManageGuestAccess)
        XCTAssertEqual(store.state?.pendingLocalReset,true); XCTAssertNil(store.state?.actionCode)
        await app.resume(); XCTAssertFalse(app.isForeground)
        failCleanup = false
        XCTAssertTrue(app.finishLocalResetCleanup()); XCTAssertEqual(calls,2)
        XCTAssertFalse(app.localResetCleanupPending); XCTAssertFalse(app.storageReady)
        let fresh = AppModel(storage:store,resetCleanup:{ _ in XCTFail("Cleanup already committed") }); defer { fresh.suspend() }
        XCTAssertTrue(fresh.storageReady); XCTAssertFalse(fresh.hasActionCode); XCTAssertFalse(fresh.appLocked)
        XCTAssertTrue(fresh.guests.isEmpty); XCTAssertTrue(fresh.owners.isEmpty)
        XCTAssertEqual(try fresh.backupFingerprint(server:"owner.invalid"),try MigrationFingerprint.ios(identity:XCTUnwrap(store.state?.identity),server:"owner.invalid"))
    }
    func testInterruptedResetRetriesCleanupBeforeNewModelBecomesReady() throws {
        let store = ResetStorage(try source()), session = LocalStateSession(store)
        try session.erase(confirmedIdentity:try XCTUnwrap(store.state?.identity))
        var fail = true, calls = 0
        let app = AppModel(storage:store,resetCleanup:{ _ in
            calls += 1; if fail { throw KeychainStore.Failure(status:-1) }
        }); defer { app.suspend() }
        XCTAssertFalse(app.storageReady); XCTAssertTrue(app.localDataErased)
        XCTAssertTrue(app.localResetCleanupPending); XCTAssertEqual(store.state?.pendingLocalReset,true)
        fail = false
        XCTAssertTrue(app.finishLocalResetCleanup()); XCTAssertEqual(calls,2)
        let fresh = AppModel(storage:store,resetCleanup:{ _ in XCTFail("Completed reset must not clean again") }); defer { fresh.suspend() }
        XCTAssertTrue(fresh.storageReady); XCTAssertTrue(fresh.guests.isEmpty); XCTAssertTrue(fresh.owners.isEmpty)
        XCTAssertFalse(fresh.hasActionCode); XCTAssertFalse(fresh.appLockEnabled)
    }
}
