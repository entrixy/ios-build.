import XCTest
@testable import EntrixyCore

final class GeoCorridorMatcherTests: XCTestCase {
    private let key = "gate"
    private let gate = AutomationGeoPoint(lat: 0,lon: 0)
    private var route: [[AutomationGeoPoint]] { [[AutomationGeoPoint(lat: 160/111320,lon: 0),gate]] }
    private func fix(_ distance: Double, _ seconds: Int64, accuracy: Float = 5, speed: Float = -1, sideways: Double = 0) -> AutomationLocationFix {
        AutomationLocationFix(latitude: distance/111320,longitude: sideways/111320,accuracyM: accuracy,speedMps: speed,timestampMS: seconds*1000)
    }
    @discardableResult private func update(_ matcher: inout GeoCorridorMatcher, _ distance: Double, _ seconds: Int64,
                                           accuracy: Float = 5, speed: Float = -1, sideways: Double = 0) -> Bool {
        matcher.update(key: key,fix: fix(distance,seconds,accuracy: accuracy,speed: speed,sideways: sideways),gate: gate,corridors: route)
    }
    func testApproachRequiresRunSpanAndTwoRecentNearFixesWithoutGPSMedianDelay() {
        var matcher = GeoCorridorMatcher()
        XCTAssertFalse(update(&matcher,120,0)); XCTAssertFalse(update(&matcher,90,10)); XCTAssertFalse(update(&matcher,60,20))
        XCTAssertFalse(update(&matcher,40,30))
        XCTAssertTrue(update(&matcher,20,40))
        // A temporary busy transport has not consumed this approach.
        XCTAssertTrue(update(&matcher,15,45))
    }
    func testParkedDriftAndGPSJitterCannotReplaceAnApproach() {
        var drift = GeoCorridorMatcher(), jitter = GeoCorridorMatcher()
        for i in 0..<7 { XCTAssertFalse(update(&drift,Double(55-i*5),Int64(i*20),speed: 0)) }
        for i in 0..<100 { XCTAssertFalse(update(&jitter,Double(i%3)*6,Int64(i),speed: 15)) }
    }
    func testUrbanPoorAccuracyContributesOnlyNearWindowNotPathOrRearm() {
        var matcher = GeoCorridorMatcher()
        for (d,t) in [(120.0,Int64(0)),(90,10),(60,20)] { XCTAssertFalse(update(&matcher,d,t)) }
        XCTAssertFalse(update(&matcher,40,25,accuracy: 80))
        XCTAssertFalse(update(&matcher,30,30,accuracy: 100))
        XCTAssertTrue(update(&matcher,45,35))
        matcher.markOpened(key)
        for i in 0..<5 { XCTAssertFalse(update(&matcher,150,Int64(40+i),accuracy: 80)) }
        XCTAssertTrue(matcher.isLatched(key))
    }
    func testConsumedApproachNeedsThreeConsecutiveRealExitFixes() {
        var matcher = GeoCorridorMatcher()
        for (i,d) in [120.0,90,60,40,20].enumerated() { _ = update(&matcher,d,Int64(i*10)) }
        matcher.markOpened(key)
        XCTAssertFalse(update(&matcher,10,45))
        XCTAssertFalse(update(&matcher,100,50)); XCTAssertFalse(update(&matcher,100,55))
        XCTAssertFalse(update(&matcher,40,60)); XCTAssertTrue(matcher.isLatched(key))
        for t in [70,80,90] { XCTAssertFalse(update(&matcher,120,Int64(t))) }
        XCTAssertFalse(matcher.isLatched(key))
        XCTAssertFalse(update(&matcher,90,100)); XCTAssertFalse(update(&matcher,60,110))
        XCTAssertFalse(update(&matcher,40,120)); XCTAssertTrue(update(&matcher,20,130))
    }
    func testWrongCorridorAndInterruptedOldRunDoNotFire() {
        var outside = GeoCorridorMatcher(), gap = GeoCorridorMatcher()
        for (i,d) in [120.0,90,60,40,20].enumerated() { XCTAssertFalse(update(&outside,d,Int64(i*10),sideways: 70)) }
        XCTAssertFalse(update(&gap,120,0)); XCTAssertFalse(update(&gap,90,10))
        XCTAssertFalse(update(&gap,40,70)); XCTAssertFalse(update(&gap,20,80))
        var stale = GeoCorridorMatcher()
        XCTAssertFalse(update(&stale,120,0)); XCTAssertFalse(update(&stale,90,10)); XCTAssertFalse(update(&stale,40,20))
        XCTAssertFalse(update(&stale,50,45))
    }
    func testRepeatedOutOfOrderAndInvalidFixesDoNotSupplyNearEvidence() {
        var matcher = GeoCorridorMatcher()
        XCTAssertFalse(update(&matcher,120,0)); XCTAssertFalse(update(&matcher,90,10)); XCTAssertFalse(update(&matcher,40,20))
        XCTAssertFalse(update(&matcher,20,20)); XCTAssertFalse(update(&matcher,10,15))
        XCTAssertFalse(update(&matcher,.nan,25)); XCTAssertFalse(update(&matcher,0,26,accuracy: -1))
        XCTAssertTrue(update(&matcher,20,30))
    }
    func testDenseFusedLocationsUseLargerOfMedianDopplerAndPositionalSpeed() {
        var matcher = GeoCorridorMatcher()
        let distances: [Double] = [100,85,70,55,40,25]
        var decisions: [Bool] = []
        for (i,d) in distances.enumerated() { decisions.append(update(&matcher,d,Int64(i*3),speed: 0)) }
        XCTAssertTrue(decisions.last == true)
        matcher.reset(key); XCTAssertFalse(matcher.isLatched(key))
        XCTAssertFalse(update(&matcher,20,30,speed: 0))
    }
}
