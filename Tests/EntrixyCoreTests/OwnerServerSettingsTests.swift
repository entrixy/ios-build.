import XCTest
@testable import EntrixyCore

final class OwnerServerSettingsTests: XCTestCase {
    func testAmbiguousRegistrationAndLegacyPendingStateNeverPermitAnotherOwner() throws {
        var owner = try OwnerAccount(server:"owner.invalid")
        let master = owner.masterKey
        XCTAssertTrue(owner.canRegisterSafely)
        try owner.markRegistrationSent(); XCTAssertFalse(owner.canRegisterSafely)
        var decoded = try JSONDecoder().decode(OwnerAccount.self,from:JSONEncoder().encode(owner))
        XCTAssertFalse(decoded.canRegisterSafely); XCTAssertEqual(decoded.masterKey,master)
        try decoded.rejectRegistration(); XCTAssertTrue(decoded.canRegisterSafely)
        XCTAssertEqual(decoded.masterKey,master)
        try decoded.markRegistrationSent(); XCTAssertFalse(decoded.canRegisterSafely)
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(owner)) as! [String:Any]
        json.removeValue(forKey:"registrationPhase")
        let legacy = try JSONDecoder().decode(OwnerAccount.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertFalse(legacy.canRegisterSafely); XCTAssertNil(legacy.registrationPhase)
        XCTAssertEqual(legacy.masterKey,master)
    }
    func testAccountSnapshotsDistinguishAbsentFieldFromConfirmedUnlink() throws {
        var owner = try OwnerAccount(server:"owner.invalid"), settings = OwnerServerSettings()
        settings.accessCode = "private-server-code"; settings.accountEmail = "owner@example.test"
        var pending = OwnerAccountLinkIntent(email:nil); pending.sent = true
        settings.pendingAccount = pending; owner.serverSettings = settings
        let missing = try OwnerSnapshot.decode(Data(#"{"numbers":[],"keys":[]}"#.utf8))
        try owner.reconcileAccount(missing)
        XCTAssertEqual(owner.serverSettings?.accountEmail,"owner@example.test"); XCTAssertNotNil(owner.serverSettings?.pendingAccount)
        let unlinked = try OwnerSnapshot.decode(Data(#"{"numbers":[],"keys":[],"account":null}"#.utf8))
        try owner.reconcileAccount(unlinked)
        XCTAssertNil(owner.serverSettings?.accountEmail); XCTAssertNil(owner.serverSettings?.pendingAccount)
        XCTAssertEqual(owner.serverSettings?.accessCode,"private-server-code")
        XCTAssertThrowsError(try OwnerSnapshot.decode(Data(#"{"numbers":[],"keys":[],"account":123}"#.utf8)))
    }
    func testLinkReconciliationDoesNotConfirmAnotherAccount() throws {
        var owner = try OwnerAccount(server:"owner.invalid"), settings = OwnerServerSettings()
        var pending = OwnerAccountLinkIntent(email:"me@example.test"); pending.sent = true
        settings.pendingAccount = pending; owner.serverSettings = settings
        try owner.reconcileAccount(OwnerSnapshot.decode(Data(#"{"numbers":[],"keys":[],"account":"other@example.test"}"#.utf8)))
        XCTAssertEqual(owner.serverSettings?.accountEmail,"other@example.test"); XCTAssertNotNil(owner.serverSettings?.pendingAccount)
        try owner.reconcileAccount(OwnerSnapshot.decode(Data(#"{"numbers":[],"keys":[],"account":"ME@example.test"}"#.utf8)))
        XCTAssertNil(owner.serverSettings?.pendingAccount)
    }
}
