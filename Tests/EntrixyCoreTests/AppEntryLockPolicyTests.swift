import XCTest
@testable import EntrixyCore

final class AppEntryLockPolicyTests: XCTestCase {
    func testColdStartGracePeriodAndExplicitUnlockMatchAndroid() {
        var policy = AppEntryLockPolicy()
        XCTAssertFalse(policy.requiresUnlock(enabled: false, hasCode: true, now: 10))
        XCTAssertTrue(policy.requiresUnlock(enabled: true, hasCode: true, now: 10))
        policy.unlocked()
        XCTAssertFalse(policy.requiresUnlock(enabled: true, hasCode: true, now: 10))
        policy.background(now: 100)
        XCTAssertFalse(policy.requiresUnlock(enabled: true, hasCode: true, now: 160))
        XCTAssertTrue(policy.requiresUnlock(enabled: true, hasCode: true, now: 160.1))
        policy.unlocked()
        XCTAssertFalse(policy.requiresUnlock(enabled: true, hasCode: true, now: 1000))
        XCTAssertTrue(AppEntryLockPolicy().requiresUnlock(enabled: true, hasCode: true, now: 1000))
    }
    func testInvalidOrReversedClockCannotExtendGrace() {
        var policy = AppEntryLockPolicy(); policy.unlocked(); policy.background(now: 100)
        XCTAssertTrue(policy.requiresUnlock(enabled: true, hasCode: true, now: 99))
        XCTAssertTrue(policy.requiresUnlock(enabled: true, hasCode: true, now: .nan))
        policy.background(now: .infinity)
        XCTAssertTrue(policy.requiresUnlock(enabled: true, hasCode: true, now: 100))
    }
}
