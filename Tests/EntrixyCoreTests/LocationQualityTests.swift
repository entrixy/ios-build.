import XCTest
@testable import EntrixyCore

final class LocationQualityTests: XCTestCase {
    func testPoorLiveProviderWarnsAfterFourMinutesButQuietProviderDoesNot() {
        var monitor = LocationQualityMonitor(); monitor.reset(at:Date(timeIntervalSince1970:1000))
        monitor.receive(at:Date(timeIntervalSince1970:1240),accuracy:300)
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1240)))
        XCTAssertTrue(monitor.unreliable(at:Date(timeIntervalSince1970:1241)))
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1330)))
    }
    func testAccurateFixAndNewTrackingSessionResetTheWarning() {
        var monitor = LocationQualityMonitor(); monitor.reset(at:Date(timeIntervalSince1970:1000))
        monitor.receive(at:Date(timeIntervalSince1970:1250),accuracy:300)
        XCTAssertTrue(monitor.unreliable(at:Date(timeIntervalSince1970:1250)))
        monitor.receive(at:Date(timeIntervalSince1970:1251),accuracy:80)
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1251)))
        monitor.reset(at:Date(timeIntervalSince1970:2000))
        monitor.receive(at:Date(timeIntervalSince1970:2001),accuracy:300)
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:2001)))
    }
    func testInvalidOrOutOfOrderFixCannotTurnPoorQualityIntoAnAccurateReading() {
        var monitor = LocationQualityMonitor(); monitor.reset(at:Date(timeIntervalSince1970:1000))
        monitor.receive(at:Date(timeIntervalSince1970:1250),accuracy:300)
        monitor.receive(at:Date(timeIntervalSince1970:1249),accuracy:5)
        monitor.receive(at:Date(timeIntervalSince1970:1251),accuracy:-1)
        XCTAssertTrue(monitor.unreliable(at:Date(timeIntervalSince1970:1251)))
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1200)))
    }
}
