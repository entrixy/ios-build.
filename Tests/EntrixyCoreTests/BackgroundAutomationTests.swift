import XCTest
@testable import EntrixyCore

final class BackgroundAutomationTests: XCTestCase {
    private let target = ObjectReference.owned(server:"owner.invalid",objectID:UUID())
    func testScopePinsTargetTemplateAndMonotonicDeadline() throws {
        var template = AutomationTemplate(); template.bleEnabled = true
        let scope = try BackgroundActionScope(target:target,transport:.bluetooth,template:template,uptime:100,duration:8)
        XCTAssertTrue(scope.allows(target,template:template,uptime:100))
        XCTAssertFalse(scope.allows(target,template:template,uptime:108))
        XCTAssertFalse(scope.allows(target,template:template,uptime:99))
        XCTAssertFalse(scope.allows(.owned(server:"another.invalid",objectID:UUID()),template:template,uptime:101))
        template.bleRadiusM = 10
        XCTAssertFalse(scope.allows(target,template:template,uptime:101))
    }
    func testPINConfirmationAndUnconfiguredRulesCannotCreateBackgroundAuthority() throws {
        for mode in 0..<4 {
            var template = AutomationTemplate(); template.bleEnabled = true
            if mode == 0 { template.authEnabled = true }
            if mode == 1 { template.confirmEnabled = true }
            if mode == 2 { template.requireConfirmation = true }
            if mode == 3 { template.bleEnabled = false }
            XCTAssertThrowsError(try BackgroundActionScope(target:target,transport:.bluetooth,template:template,uptime:100,duration:8))
        }
    }
    func testUnboundedOrInvalidWindowsAreRejected() throws {
        var template = AutomationTemplate(); template.bleEnabled = true
        for seconds in [0,-1,21,Double.infinity,Double.nan] {
            XCTAssertThrowsError(try BackgroundActionScope(target:target,transport:.bluetooth,template:template,uptime:100,duration:seconds))
        }
    }
    func testCoalescedNearPacketsCannotRearmEvenAfterHoursOfSilence() {
        var rearm = BLEBackgroundRearm()
        for date in [100.0,1000,10000,20000] { XCTAssertFalse(rearm.receive(key:"gate",rssi:-40,radiusM:3,now:date)) }
    }
    func testFarRearmNeedsThreeActualSpacedSamplesAndNearSignalResetsEvidence() {
        var rearm = BLEBackgroundRearm()
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:100))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:100.1))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:105))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-40,radiusM:3,now:106))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:110))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:115))
        XCTAssertTrue(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:120))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-40,radiusM:3,now:125))
    }
    func testOldFarSamplesAndRestartCannotInferRadioExit() {
        var rearm = BLEBackgroundRearm()
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:100))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:200))
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:205))
        rearm.reset()
        XCTAssertFalse(rearm.receive(key:"gate",rssi:-90,radiusM:3,now:210))
    }
}
