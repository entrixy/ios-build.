import XCTest
@testable import EntrixyCore

final class OwnerManualPolicyTests: XCTestCase {
    func testOriginalOwnerAuthenticationAndCombinedRulesRemainEnforced() throws {
        let auth = try OwnerManualPolicy(Data(#"{"auth_on":true,"auth":"biometric","confirm_on":true}"#.utf8))
        XCTAssertEqual(auth.authentication, "biometric"); XCTAssertTrue(auth.confirmation)
        XCTAssertNil(auth.blockedReason)
        let combined = try OwnerManualPolicy(Data(#"{"mode":"all","geo_on":true,"wifi_on":true}"#.utf8))
        XCTAssertNotNil(combined.blockedReason)
        let manualOverride = try OwnerManualPolicy(Data(#"{"mode":"any","geo_on":true,"wifi_on":true}"#.utf8))
        XCTAssertNil(manualOverride.blockedReason)
        XCTAssertThrowsError(try OwnerManualPolicy(Data(#"{"auth_on":1,"auth":"pin"}"#.utf8)))
        XCTAssertThrowsError(try OwnerManualPolicy(Data(#"{"auth_on":true,"auth":"unknown"}"#.utf8)))
    }
}
