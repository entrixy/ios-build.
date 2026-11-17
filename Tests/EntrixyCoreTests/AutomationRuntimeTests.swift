import XCTest
@testable import EntrixyCore

final class AutomationRuntimeTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func fix(_ distance: Double, _ seconds: Int64, accuracy: Float = 5) -> AutomationLocationFix {
        AutomationLocationFix(latitude:distance/111195,longitude:0,accuracyM:accuracy,timestampMS:seconds*1000)
    }
    func testBLEUsesItsOwnRadioLatchAndRequiresAnActualBLEObservation() {
        var runtime = AutomationRuntime(sessionStarted:100), template = AutomationTemplate(); template.bleEnabled = true
        let absent = runtime.evaluate(key:"a",template:template,date:date(101),bleReady:false)
        XCTAssertFalse(absent.forBLE(armed:true).ready)
        let nearby = runtime.evaluate(key:"a",template:template,date:date(102),bleReady:true)
        XCTAssertTrue(nearby.forBLE(armed:true).ready)
        XCTAssertFalse(nearby.forBLE(armed:false).ready)
        runtime.consume("a",route:false,at:date(102))
        // A real radio exit is the BLE rearm source, rather than GPS cooldown.
        XCTAssertTrue(runtime.evaluate(key:"a",template:template,date:date(103),bleReady:true).forBLE(armed:true).ready)
    }

    func testStartingInsideWiFiDoesNotFireUntilActualExitAndNewEntry() {
        var runtime = AutomationRuntime(sessionStarted:100), template = AutomationTemplate()
        template.wifiEnabled = true
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(101),wifiMatches:1,wifiRequired:1).ready)
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(102),wifiMatches:0,wifiRequired:1).ready)
        XCTAssertTrue(runtime.evaluate(key:"a",template:template,date:date(103),wifiMatches:1,wifiRequired:1).ready)
        runtime.consume("a",route:false,at:date(103))
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(400),wifiMatches:1,wifiRequired:1).ready)
        _ = runtime.evaluate(key:"a",template:template,date:date(401),wifiMatches:0,wifiRequired:1)
        XCTAssertTrue(runtime.evaluate(key:"a",template:template,date:date(402),wifiMatches:1,wifiRequired:1).ready)
    }
    func testGeoRequiresObservedOutsideOrangeThenTenSecondsContinuousDwell() {
        var runtime = AutomationRuntime(sessionStarted:100), template = AutomationTemplate()
        template.geoEnabled = true; template.geoLat = 0; template.geoLon = 0; template.radiusM = 30
        runtime.receive(fix(500,101))
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(101)).ready)
        runtime.receive(fix(20,110))
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(110)).ready)
        runtime.receive(fix(20,115))
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(115)).ready)
        runtime.receive(fix(20,120))
        XCTAssertTrue(runtime.evaluate(key:"a",template:template,date:date(120)).ready)
        runtime.consume("a",route:false,at:date(120))
        runtime.receive(fix(20,400))
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(400)).ready)
    }
    func testTimerWithNoGPSNeverManufacturesOutsideEntryAndStalePositionCannotPass() {
        var runtime = AutomationRuntime(sessionStarted:100), template = AutomationTemplate()
        template.geoEnabled = true; template.geoLat = 0; template.geoLon = 0
        _ = runtime.evaluate(key:"a",template:template,date:date(101))
        runtime.receive(fix(10,105))
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(105)).matched)
        XCTAssertNil(runtime.evaluate(key:"a",template:template,date:date(106)).observations.lastOutsideOrange)
        runtime.receive(fix(500,110)); _ = runtime.evaluate(key:"a",template:template,date:date(110))
        runtime.receive(fix(10,115)); _ = runtime.evaluate(key:"a",template:template,date:date(115))
        XCTAssertTrue(runtime.evaluate(key:"a",template:template,date:date(125)).ready)
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(146)).matched)
    }
    func testAllConditionsUseSameObservationsAndChangedTemplateRequiresNewEntry() {
        var runtime = AutomationRuntime(sessionStarted:100), template = AutomationTemplate()
        template.wifiEnabled = true; template.bleEnabled = true; template.combineMode = "all"
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(101),wifiMatches:0,wifiRequired:1,bleReady:true).matched)
        let both = runtime.evaluate(key:"a",template:template,date:date(102),wifiMatches:1,wifiRequired:1,bleReady:true)
        XCTAssertTrue(both.ready); XCTAssertTrue(both.matched)
        template.confirmEnabled = true
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(103),wifiMatches:1,wifiRequired:1,bleReady:true).ready)
    }
    func testRouteFiresWithoutZoneDwellAndLatchSurvivesTimers() {
        var runtime = AutomationRuntime(sessionStarted:100), template = AutomationTemplate()
        template.geoEnabled = true; template.geoMode = "route"; template.geoLat = 0; template.geoLon = 0
        template.corridors = [[AutomationGeoPoint(lat:160/111320,lon:0),AutomationGeoPoint(lat:0,lon:0)]]
        var result: AutomationReadiness?
        for (i,d) in [120.0,90,60,40,20].enumerated() {
            let second = Int64(101+i*10); runtime.receive(fix(d,second)); result = runtime.evaluate(key:"a",template:template,date:date(Double(second)))
        }
        XCTAssertTrue(result?.ready == true); XCTAssertTrue(result?.routeMatched == true)
        runtime.consume("a",route:true,at:date(141))
        XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(150)).ready)
        runtime.receive(fix(10,155)); XCTAssertFalse(runtime.evaluate(key:"a",template:template,date:date(155)).ready)
    }
}
