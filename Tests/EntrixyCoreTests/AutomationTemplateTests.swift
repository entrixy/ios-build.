import XCTest
@testable import EntrixyCore

final class AutomationTemplateTests: XCTestCase {
    func testAndroidWireNamesLegacyLevelsAndUnknownFieldsRoundTrip() throws {
        let bytes = Data(#"{"mode":"all","geo_on":true,"point_l":"own","rad_l":"force","lat":55.1,"lon":37.2,"rad":50,"corridors":[[[55.1,37.2],[55.2,37.3]]],"time_on":true,"time_e":[{"wd":[2,3,6],"f":1320,"t":360}],"future":{"identifier":18446744073709551614}}"#.utf8)
        let t = try AutomationTemplate(data: bytes)
        XCTAssertEqual(t.geoLevel, .force); XCTAssertEqual(t.timeEntries[0].weekdays, [2,3,6])
        let encoded = try t.data(), second = try AutomationTemplate(data: encoded)
        XCTAssertEqual(t, second); XCTAssertEqual(encoded, try second.data())
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("18446744073709551614"))
    }
    func testSuggestionTracksOnlyValuesTheGuestDidNotChange() throws {
        var old = AutomationTemplate(); old.geoEnabled = true; old.geoLat = 55; old.geoLon = 37; old.radiusM = 100
        old.timeEnabled = true; old.timeEntries = [AutomationTimeEntry(weekdays: [2], fromMin: 480, toMin: 600)]
        var guest = old; guest.radiusM = 25
        var owner = old; owner.radiusM = 80; owner.geoLat = 56
        owner.timeEntries[0].fromMin = 540
        let merged = AutomationTemplate.mergingIncoming(previous: guest, owner: owner, previousOwner: old)
        XCTAssertEqual(merged.radiusM, 25); XCTAssertEqual(merged.geoLat, 56)
        XCTAssertEqual(merged.timeEntries[0].fromMin, 540)
        XCTAssertEqual(merged.ownerRadiusMaxM, 80)
    }
    func testForceBoundsHaveDifferentDirectionsAndCannotResetBLE() throws {
        var owner = AutomationTemplate(); owner.geoLevel = .force; owner.geoEnabled = true
        owner.geoLat = 55; owner.geoLon = 37; owner.radiusM = 50
        owner.wifiLevel = .force; owner.wifiMinMatch = 3; owner.wifiBssids = ["aa:bb:cc:dd:ee:ff"]
        owner.bleEnabled = true; owner.bleLevel = .suggest; owner.ownerBleRadiusMaxM = 6
        var guest = owner; guest.radiusM = 100; guest.geoLat = 1; guest.wifiMinMatch = 1; guest.bleRadiusM = 20
        let merged = AutomationTemplate.mergingIncoming(previous: guest, owner: owner, previousOwner: owner)
        XCTAssertEqual(merged.radiusM, 50); XCTAssertEqual(merged.geoLat, 55)
        XCTAssertEqual(merged.wifiMinMatch, 3); XCTAssertEqual(merged.wifiBssids, owner.wifiBssids)
        XCTAssertTrue(merged.bleEnabled); XCTAssertEqual(merged.bleRadiusM, 6)
        guest.radiusM = 20; guest.wifiMinMatch = 5
        let stricter = AutomationTemplate.mergingIncoming(previous: guest, owner: owner, previousOwner: owner)
        XCTAssertEqual(stricter.radiusM, 20); XCTAssertEqual(stricter.wifiMinMatch, 5)
    }
    func testFirstMergeUsesCompleteOwnerRouteAndDisablesOwnerReferenceFlag() throws {
        var owner = AutomationTemplate(); owner.geoLat = 55; owner.geoLon = 37; owner.geoFromOwner = true
        owner.geoMode = "route"; owner.corridors = [[.init(lat: 55, lon: 37), .init(lat: 55.01, lon: 37.01)]]
        let first = AutomationTemplate.mergingIncoming(previous: nil, owner: owner, previousOwner: nil)
        XCTAssertEqual(first.corridors, owner.corridors); XCTAssertFalse(first.geoFromOwner)
        var old = AutomationTemplate(); old.geoLat = 54; old.geoLon = 36
        XCTAssertEqual(AutomationTemplate.mergingIncoming(previous: old, owner: owner, previousOwner: nil).corridors, owner.corridors)
    }
    func testResolvingObjectGeoDoesNotCopyAuthenticationOrOtherGuestsRules() throws {
        var object = AutomationTemplate(); object.geoLat = 55; object.geoLon = 37; object.radiusM = 100; object.authEnabled = true; object.authMode = "biometric"
        var guest = AutomationTemplate(); guest.geoFromOwner = true; guest.radiusM = 15; guest.authMode = "pin"
        let resolved = guest.resolvingGeo(from: object)
        XCTAssertEqual(resolved.radiusM, 100); XCTAssertEqual(resolved.authMode, "pin")
        XCTAssertFalse(resolved.authEnabled); XCTAssertFalse(resolved.geoFromOwner)
    }
    func testMalformedEnabledFieldsAndGeometryFailClosed() throws {
        for raw in [#"{"geo_on":1}"#, #"{"lat":91,"lon":37}"#, #"{"lat":55}"#, #"{"mode":"other"}"#, #"{"time_e":[{"wd":[8],"f":480,"t":600}]}"#] {
            XCTAssertThrowsError(try AutomationTemplate(data: Data(raw.utf8)), raw)
        }
    }
}
