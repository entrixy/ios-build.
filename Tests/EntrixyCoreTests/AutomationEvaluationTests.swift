import XCTest
@testable import EntrixyCore

final class AutomationEvaluationTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testOvernightWindowsUseStartDayIncludingSundayRollover() {
        let monday = AutomationTimeEntry(weekdays: [2], fromMin: 22*60, toMin: 6*60)
        XCTAssertEqual(AutomationEvaluation.secondsLeftInWindow(monday, weekday: 2, seconds: 23*3600), 7*3600)
        XCTAssertEqual(AutomationEvaluation.secondsLeftInWindow(monday, weekday: 3, seconds: 2*3600), 4*3600)
        XCTAssertNil(AutomationEvaluation.secondsLeftInWindow(monday, weekday: 2, seconds: 2*3600))
        XCTAssertNil(AutomationEvaluation.secondsLeftInWindow(monday, weekday: 3, seconds: 6*3600))
        let sunday = AutomationTimeEntry(weekdays: [1], fromMin: 22*60, toMin: 6*60)
        XCTAssertEqual(AutomationEvaluation.secondsLeftInWindow(sunday, weekday: 2, seconds: 2*3600), 4*3600)
    }
    func testAnyUsesThreeMinuteMomentAndAllRetainsMomentsAfterModeChange() {
        var template = AutomationTemplate(); template.timeEnabled = true
        template.timeEntries = [AutomationTimeEntry(weekdays: [2], fromMin: 8*60, toMin: 10*60)]
        XCTAssertTrue(AutomationEvaluation.timeReady(template, date: date("2026-11-16T08:02:59Z"), calendar: calendar))
        XCTAssertFalse(AutomationEvaluation.timeReady(template, date: date("2026-11-16T08:03:00Z"), calendar: calendar))
        XCTAssertFalse(AutomationEvaluation.timeReady(template, date: date("2026-11-17T08:00:00Z"), calendar: calendar))
        template.combineMode = "all"
        XCTAssertTrue(AutomationEvaluation.timeReady(template, date: date("2026-11-16T09:00:00Z"), calendar: calendar))
        template.timeEntries[0].toMin = 8*60
        XCTAssertTrue(AutomationEvaluation.timeReady(template, date: date("2026-11-16T08:01:00Z"), calendar: calendar))
        XCTAssertFalse(AutomationEvaluation.timeReady(template, date: date("2026-11-16T09:00:00Z"), calendar: calendar))
    }
    func testNoChannelsAndEmptyScheduleDoNotMakeAutomaticActionReady() {
        let now = date("2026-11-16T08:00:00Z")
        var template = AutomationTemplate(); template.combineMode = "all"; template.timeEnabled = true
        var input = AutomationObservations(sessionStarted: now.timeIntervalSince1970-100)
        XCTAssertFalse(AutomationEvaluation.matched(template, observations: input, date: now, calendar: calendar))
        template.wifiEnabled = true; input.wifiMatches = 2; input.wifiRequired = 2
        XCTAssertTrue(AutomationEvaluation.matched(template, observations: input, date: now, calendar: calendar))
    }
    func testGeoRequiresFreshOutsideObservationFromThisSessionAndBLEParticipatesInAll() {
        let now = date("2026-11-16T08:00:00Z"), epoch = now.timeIntervalSince1970
        var template = AutomationTemplate(); template.geoEnabled = true; template.bleEnabled = true; template.combineMode = "all"
        var input = AutomationObservations(sessionStarted: epoch-100); input.geoMatched = true; input.bleReady = true
        input.lastOutsideOrange = epoch-200
        XCTAssertFalse(AutomationEvaluation.matched(template, observations: input, date: now))
        input.lastOutsideOrange = epoch-50
        XCTAssertTrue(AutomationEvaluation.matched(template, observations: input, date: now))
        input.bleReady = false
        XCTAssertFalse(AutomationEvaluation.matched(template, observations: input, date: now))
        template.combineMode = "any"
        XCTAssertTrue(AutomationEvaluation.matched(template, observations: input, date: now))
    }
    func testIncomingLocalEditCannotChangeForcedEnablementOrGeometry() throws {
        var owner = AutomationTemplate(); owner.combineLevel = .force; owner.combineMode = "all"
        owner.geoLevel = .force; owner.geoEnabled = true; owner.geoLat = 55; owner.geoLon = 37; owner.radiusM = 50
        owner.authLevel = .force; owner.authEnabled = true; owner.authMode = "pin"
        var record = IncomingAutomationConfiguration(owner: owner), edit = record.effective
        edit.geoEnabled = false; edit.geoLat = 1; edit.geoLon = 1; edit.radiusM = 100
        edit.authEnabled = false; edit.authMode = "biometric"; edit.combineMode = "any"
        try record.edit(edit)
        XCTAssertTrue(record.effective.geoEnabled); XCTAssertEqual(record.effective.geoLat, 55)
        XCTAssertEqual(record.effective.radiusM, 50); XCTAssertEqual(record.effective.combineMode, "all")
        XCTAssertTrue(record.effective.authEnabled); XCTAssertEqual(record.effective.authMode, "pin")
    }
}
