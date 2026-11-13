import XCTest
@testable import EntrixyCore

final class ControlFrameValidationTests: XCTestCase {
    func testBLEMaintenanceFramesRespectWebSocketRoleBoundary() throws {
        let request = Data(#"{"type":"ble_revokes_req"}"#.utf8)
        XCTAssertEqual(try ControlFrameValidation.guest(request), String(decoding: request, as: UTF8.self))
        XCTAssertThrowsError(try ControlFrameValidation.owner(request))
        let decision = try BLERevocation(deviceID: 0xf1234567, guestID: 9, version: 100, revoked: true, ownerSecret: Data(repeating: 7, count: 32))
        let frame = try JSONSerialization.data(withJSONObject: decision.json)
        XCTAssertEqual(try ControlFrameValidation.owner(frame), String(decoding: frame, as: UTF8.self))
        XCTAssertThrowsError(try ControlFrameValidation.guest(frame))
        var malformed = decision.json; malformed["sig"] = "bad"
        XCTAssertThrowsError(try ControlFrameValidation.owner(JSONSerialization.data(withJSONObject: malformed)))
        XCTAssertThrowsError(try ControlFrameValidation.guest(Data(#"{"type":"ble_revokes_req","user_key":"must-not-be-sent"}"#.utf8)))
        if case .bleRevocations = try GuestEvent.decode(JSONSerialization.data(withJSONObject: ["type": "ble_revokes", "items": [decision.json]])) {} else { XCTFail("Signed decisions must reach the protected guest cache") }
    }
}
