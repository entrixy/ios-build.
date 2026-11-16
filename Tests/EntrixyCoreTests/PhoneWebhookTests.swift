import XCTest
@testable import EntrixyCore

final class PhoneWebhookTests: XCTestCase {
    func testSignatureMatchesIndependentPythonHMACFixture() throws {
        let bytes = try PhoneWebhook.request(numberID: 7, action: .close, secret: "секрет", epoch: 1700000000, nonce: Data(0...7))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["signature"] as? String, "f80c48d39147faf1c8389361b87787213e2a43116d62887f50189bb219488827")
        XCTAssertEqual(json["nonce"] as? String, "0001020304050607")
        XCTAssertEqual(json["object_id"] as? Int, 7)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("секрет"))
        XCTAssertThrowsError(try PhoneWebhook.request(numberID: 7, action: .toggle, secret: "key"))
    }
    func testExplicitGuestDirectionWinsOverOwnerToggleDefault() {
        XCTAssertEqual(PhoneWebhook.action(requested: .open, toggles: true, position: "open"), .open)
        XCTAssertEqual(PhoneWebhook.action(requested: nil, toggles: true, position: "open"), .close)
        XCTAssertEqual(PhoneWebhook.action(requested: nil, toggles: false, position: "open"), .open)
        XCTAssertEqual(PhoneWebhook.action(requested: .toggle, toggles: false, position: "opening"), .close)
    }
    func testReplyMatchesLevelLegacyAndPlainHTTPResponses() throws {
        XCTAssertEqual(try PhoneWebhook.reply(status: 204, data: Data()).level, "success")
        XCTAssertEqual(try PhoneWebhook.reply(status: 503, data: Data("unavailable".utf8)).level, "danger")
        XCTAssertEqual(try PhoneWebhook.reply(status: 200, data: Data(#"{"status":"error"}"#.utf8)).level, "danger")
        let modern = try PhoneWebhook.reply(status: 400, data: Data(#"{"level":"warning","status":"error","message":"Свой ответ","position":"closed","close_in":99999}"#.utf8))
        XCTAssertEqual(modern.level,"warning"); XCTAssertEqual(modern.message,"Свой ответ")
        XCTAssertEqual(modern.position,"closed"); XCTAssertEqual(modern.closeIn,3600)
        XCTAssertEqual(try PhoneWebhook.reply(status:200,data:Data(#"{"message":"","position":"moving","close_in":-1}"#.utf8)).message,nil)
    }
    func testPositionForgettingUsesReceiverDeadlineWithoutSendingAnotherCommand() throws {
        let reply = try PhoneWebhook.reply(status: 200, data: Data(#"{"close_in":15}"#.utf8))
        XCTAssertNil(reply.positionAfter(action: .open, toggles: false))
        XCTAssertEqual(reply.positionAfter(action: .open, toggles: true), "open")
        XCTAssertEqual(reply.forgetting(position: "open").after, 15)
        XCTAssertEqual(reply.forgetting(position: "open").position, "closed")
        XCTAssertEqual(reply.forgetting(position: "closed").position, "unknown")
        let failure = try PhoneWebhook.reply(status: 500, data: Data())
        XCTAssertNil(failure.positionAfter(action: .close, toggles: true))
    }
}
