import XCTest
@testable import Entrixy

private final class EntryLockStorage: StateStorage {
    var state: SavedState? = SavedState(identity: Data(repeating: 9, count: 32), guests: [])
    var fail = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if fail { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}

@MainActor final class AppEntryLockTests: XCTestCase {
    func testColdStartAndBackgroundLockRequireCodeAndDisablingCannotBypassIt() async throws {
        let storage = EntryLockStorage(), app = AppModel(storage: EntryLockStorage())
        // Separate fixture stores verify settings persist rather than leaking process state.
        let configured = AppModel(storage: storage)
        try await configured.setActionCode("1234")
        let enabled = try await configured.configureEntryLock(enabled: true, biometric: false, code: "")
        XCTAssertTrue(enabled)
        let relaunched = AppModel(storage: storage)
        XCTAssertTrue(relaunched.appLocked)
        let denied = try await relaunched.unlockApplication(code: "0000")
        XCTAssertFalse(denied); XCTAssertTrue(relaunched.appLocked)
        let accepted = try await relaunched.unlockApplication(code: "1234")
        XCTAssertTrue(accepted); XCTAssertFalse(relaunched.appLocked)
        relaunched.entryDidBackground(now: 100); relaunched.checkEntryLock(now: 160)
        XCTAssertFalse(relaunched.appLocked)
        relaunched.checkEntryLock(now: 161); XCTAssertTrue(relaunched.appLocked)
        let reentered = try await relaunched.unlockApplication(code: "1234"); XCTAssertTrue(reentered)
        let wrong = try await relaunched.configureEntryLock(enabled: false, biometric: false, code: "0000")
        XCTAssertFalse(wrong); XCTAssertTrue(relaunched.appLockEnabled)
        let disabled = try await relaunched.configureEntryLock(enabled: false, biometric: false, code: "1234")
        XCTAssertTrue(disabled); XCTAssertFalse(AppModel(storage: storage).appLocked)
        XCTAssertFalse(app.appLocked)
        XCTAssertEqual(storage.state?.identity, Data(repeating: 9, count: 32))
    }
    func testFailedPreferenceWriteAndCodeChangePreserveExistingProtection() async throws {
        let storage = EntryLockStorage(), app = AppModel(storage: EntryLockStorage())
        let configured = AppModel(storage: storage)
        try await configured.setActionCode("1234")
        _ = try await configured.configureEntryLock(enabled: true, biometric: false, code: "")
        storage.fail = true
        do { _ = try await configured.configureEntryLock(enabled: false, biometric: false, code: "1234"); XCTFail("Save must fail") } catch {}
        XCTAssertTrue(configured.appLockEnabled)
        storage.fail = false
        let wrong = try await configured.changeActionCode(current: "0000", replacement: "5678")
        XCTAssertFalse(wrong)
        let changed = try await configured.changeActionCode(current: "1234", replacement: "5678")
        XCTAssertTrue(changed)
        let relaunched = AppModel(storage: storage)
        let old = try await relaunched.unlockApplication(code: "1234"); XCTAssertFalse(old)
        let new = try await relaunched.unlockApplication(code: "5678"); XCTAssertTrue(new)
        XCTAssertTrue(configured.appLockEnabled)
        XCTAssertFalse(app.hasActionCode)
    }
}
