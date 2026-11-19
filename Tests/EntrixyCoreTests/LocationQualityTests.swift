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
    func testFrozenAccurateCoordinatesRequireRecentIndependentMotion() {
        var monitor = LocationQualityMonitor(); monitor.reset(at:Date(timeIntervalSince1970:1000))
        let point = AutomationGeoPoint(lat:55,lon:37)
        monitor.receive(at:Date(timeIntervalSince1970:1000),accuracy:9,position:point)
        monitor.receive(at:Date(timeIntervalSince1970:1241),accuracy:9,position:point)
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1241)))
        monitor.receiveMotion(at:Date(timeIntervalSince1970:1241),acceleration:0.2)
        XCTAssertTrue(monitor.unreliable(at:Date(timeIntervalSince1970:1241)))
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1301)))
    }
    func testRealPositionChangeBeyondFortyMetersResetsFrozenWarningButNoiseDoesNot() {
        var monitor = LocationQualityMonitor(); monitor.reset(at:Date(timeIntervalSince1970:1000))
        monitor.receive(at:Date(timeIntervalSince1970:1000),accuracy:10,position:AutomationGeoPoint(lat:55,lon:37))
        monitor.receive(at:Date(timeIntervalSince1970:1241),accuracy:10,position:AutomationGeoPoint(lat:55.0001,lon:37))
        monitor.receiveMotion(at:Date(timeIntervalSince1970:1241),acceleration:0.3)
        XCTAssertTrue(monitor.unreliable(at:Date(timeIntervalSince1970:1241)))
        // An inaccurate GPS jump must not reset the accurate-position anchor.
        monitor.receive(at:Date(timeIntervalSince1970:1242),accuracy:300,position:AutomationGeoPoint(lat:56,lon:37))
        XCTAssertTrue(monitor.unreliable(at:Date(timeIntervalSince1970:1242)))
        monitor.receive(at:Date(timeIntervalSince1970:1243),accuracy:10,position:AutomationGeoPoint(lat:55.001,lon:37))
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1243)))
    }
    func testNoisyInvalidOrPreSessionMotionCannotFabricateFrozenLocationWarning() {
        var monitor = LocationQualityMonitor(); monitor.reset(at:Date(timeIntervalSince1970:1000))
        let point = AutomationGeoPoint(lat:55,lon:37)
        monitor.receive(at:Date(timeIntervalSince1970:1000),accuracy:9,position:point)
        monitor.receive(at:Date(timeIntervalSince1970:1241),accuracy:9,position:point)
        for (time,acceleration) in [(1241.0,0.199),(1241.0,Double.nan),(1241.0,Double.infinity),(999.0,1)] {
            monitor.receiveMotion(at:Date(timeIntervalSince1970:time),acceleration:acceleration)
        }
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1241)))
        monitor.receiveMotion(at:Date(timeIntervalSince1970:1242),acceleration:1)
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1241)))
        monitor.reset(at:Date(timeIntervalSince1970:1250))
        monitor.receive(at:Date(timeIntervalSince1970:1491),accuracy:10,position:point)
        XCTAssertFalse(monitor.unreliable(at:Date(timeIntervalSince1970:1491)))
    }

}
