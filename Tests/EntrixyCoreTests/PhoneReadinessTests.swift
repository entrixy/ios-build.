import XCTest
@testable import EntrixyCore

final class PhoneReadinessTests: XCTestCase {
    private let unknown = PhonePermissionState(location:.unknown,precise:false,bluetooth:.unknown,notifications:.unknown)
    func testEmptyAndBluetoothOnlyProfilesDoNotAskForLocationOrBackground() {
        var needs = PhoneRequirements()
        XCTAssertEqual(unknown.missing(needs),[])
        needs.bluetooth = true
        XCTAssertEqual(unknown.missing(needs),[.bluetooth])
        needs.backgroundLocation = true
        XCTAssertEqual(unknown.missing(needs),[.bluetooth])
    }
    func testLocationIsRequestedBeforePrecisionAndAlwaysOnlyWhenActuallyRequired() {
        var needs = PhoneRequirements(); needs.location = true; needs.preciseLocation = true
        XCTAssertEqual(unknown.missing(needs),[.location])
        let foreground = PhonePermissionState(location:.whenInUse,precise:false,bluetooth:.allowed,notifications:.allowed)
        XCTAssertEqual(foreground.missing(needs),[.preciseLocation])
        needs.backgroundLocation = true
        XCTAssertEqual(foreground.missing(needs),[.preciseLocation,.backgroundLocation])
        XCTAssertEqual(PhonePermissionState(location:.always,precise:true,bluetooth:.allowed,notifications:.allowed).missing(needs),[])
    }
    func testNotificationsAndBluetoothAreIndependentOfLocationReadiness() {
        var needs = PhoneRequirements(); needs.notifications = true; needs.bluetooth = true
        let value = PhonePermissionState(location:.always,precise:true,bluetooth:.denied,notifications:.denied)
        XCTAssertEqual(value.missing(needs),[.bluetooth,.notifications])
        needs.bluetooth = false
        XCTAssertEqual(value.missing(needs),[.notifications])
    }
}
