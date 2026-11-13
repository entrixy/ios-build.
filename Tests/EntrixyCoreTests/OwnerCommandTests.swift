import Foundation
import XCTest
@testable import EntrixyCore

final class OwnerCommandTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "socket-owner-grant", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private var challenge: [String: Any] {
        ["number_id": 7, "command_id": "owner-fixture", "nonce": Data(0..<16).base64EncodedString()]
    }
    func testIndependentOwnerOpenCloseProofAndNoReplay() throws {
        let f = try fixture(), secret = Data(0..<32)
        for (action, field) in [(GuestAction.open, "ownerProofOpen"), (.close, "ownerProofClose")] {
            var command = try OwnerCommand(numberID: 7, kind: "device", action: action, secret: secret, now: 10)
            let request = try JSONSerialization.jsonObject(with: command.request()) as! [String: Any]
            XCTAssertEqual(request["type"] as? String, "host_self_call")
            XCTAssertEqual(request["action"] as? String, action.rawValue)
            let fire = try JSONSerialization.jsonObject(with: command.fire(challenge: challenge, now: 11)) as! [String: Any]
            XCTAssertEqual(fire["proof"] as? String, f[field] as? String)
            XCTAssertEqual(fire["token"] as? String, "")
            XCTAssertEqual(fire["guest_id"] as? Int, 0)
            XCTAssertThrowsError(try command.fire(challenge: challenge, now: 12))
        }
    }
    func testExpiredWrongObjectAndUnprovisionedCommandsAreBlocked() throws {
        XCTAssertThrowsError(try OwnerCommand(numberID: 7, kind: "device", action: .open, secret: nil, now: 10))
        XCTAssertThrowsError(try OwnerCommand(numberID: 7, kind: "call", action: .open, secret: nil, now: 10))
        var command = try OwnerCommand(numberID: 7, kind: "device", action: .open, secret: Data(0..<32), now: 10)
        var wrong = challenge; wrong["number_id"] = 8
        XCTAssertThrowsError(try command.fire(challenge: wrong, now: 11))
        XCTAssertThrowsError(try command.fire(challenge: challenge, now: 9))
        XCTAssertThrowsError(try command.fire(challenge: challenge, now: 40))
        XCTAssertNoThrow(try command.fire(challenge: challenge, now: 11))
    }
    func testServerWebhookRequestHasNoOwnerOnlySecret() throws {
        let command = try OwnerCommand(numberID: 7, kind: "webhook", action: .open, secret: nil, now: 10)
        let json = try JSONSerialization.jsonObject(with: command.request()) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "host_self_webhook")
        XCTAssertEqual(Set(json.keys), ["type", "number_id", "action"])
    }
    func testGuestPressMatchesAndroidInvitationSignatureAndRejectsChangedContext() throws {
        let user = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX", ts: Int64 = 1_800_000_000
        let nonce = String(repeating: "a", count: 32)
        let frame = try GuestPress.frame(userKey: user, host: "owner.invalid", numberID: 7, wireAction: "", timestamp: ts, nonce: nonce)
        let json = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        let press = json["press"] as! [String: Any]
        XCTAssertEqual(try OwnerGuestPress.verify(press, userKey: user, server: "owner.invalid", numberID: 7, now: ts), nonce)
        XCTAssertThrowsError(try OwnerGuestPress.verify(press, userKey: user, server: "other.invalid", numberID: 7, now: ts))
        XCTAssertThrowsError(try OwnerGuestPress.verify(press, userKey: user, server: "owner.invalid", numberID: 8, now: ts))
        XCTAssertThrowsError(try OwnerGuestPress.verify(press, userKey: user, server: "owner.invalid", numberID: 7, now: ts + 181))
        var changed = press; changed["action"] = "close"
        XCTAssertThrowsError(try OwnerGuestPress.verify(changed, userKey: user, server: "owner.invalid", numberID: 7, now: ts))
    }
}
