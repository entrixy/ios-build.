import Foundation
import XCTest
@testable import EntrixyCore

final class GuestEventTests: XCTestCase {
    private func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testMalformedUpdateCannotClearSavedObjects() throws {
        XCTAssertThrowsError(try GuestEvent.decode(bytes(["type": "numbers_update", "numbers": "wrong"])))
        XCTAssertThrowsError(try GuestEvent.decode(bytes(["type": "guest_ok"])))
        if case .numbers = try GuestEvent.decode(bytes(["type": "numbers_update", "numbers": []])) {} else { XCTFail() }
    }

    func testPauseResumeAndRevocationAreDistinctFromTransientErrors() throws {
        if case .mode(let paused) = try GuestEvent.decode(bytes(["type": "mode_update", "mode": "off"])) { XCTAssertTrue(paused) } else { XCTFail() }
        if case .mode(let paused) = try GuestEvent.decode(bytes(["type": "mode_update", "mode": "auto"])) { XCTAssertFalse(paused) } else { XCTFail() }
        if case .ignore = try GuestEvent.decode(bytes(["type": "mode_update", "mode": "unknown"])) {} else { XCTFail() }
        if case .unavailable(let reason) = try GuestEvent.decode(bytes(["type": "error", "reason": "expired"])) { XCTAssertEqual(reason, "expired") } else { XCTFail() }
        XCTAssertThrowsError(try GuestEvent.decode(bytes(["type": "error", "reason": "server_error"])))
    }

    func testPlainAvatarCannotReplaceOwnerCiphertext() throws {
        if case .avatarUnavailable(7) = try GuestEvent.decode(bytes(["type": "avatar_data", "number_id": 7, "avatar": "forged"])) {} else { XCTFail() }
        let old = Data(repeating: 9, count: 32), current = Data(repeating: 10, count: 32)
        let bundle = try bytes(["obj_keys": ["7": GuestCrypto.base64URL(current)], "obj_keys_prev": ["7": GuestCrypto.base64URL(old)]])
        let content = Data("image fixture".utf8)
        let cipher = try GuestCrypto.encrypt(key: old, plaintext: content)
        XCTAssertEqual(try GuestObjects.decryptAvatar(bundle: bundle, numberID: 7, envelope: cipher), content)
        XCTAssertThrowsError(try GuestObjects.decryptAvatar(bundle: bundle, numberID: 8, envelope: cipher))
        XCTAssertThrowsError(try GuestObjects.decryptAvatar(bundle: bundle, numberID: 7, envelope: "v1:AAAA"))
    }

    func testIncomingAppLinkPreservesServerAndRejectsOtherRoutes() throws {
        let blob = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43)
        let text = try GuestInvite.incomingText("entrixy://key#" + blob + "&h=gate.example")
        XCTAssertEqual(try GuestInvite.parse(text).server, "gate.example")
        for raw in ["entrixy://other#" + blob, "entrixy://user@key#" + blob, "entrixy://key?extra=1#" + blob, "javascript:alert(1)"] {
            XCTAssertThrowsError(try GuestInvite.incomingText(raw))
        }
    }
    func testAvatarReadsAreSerializedAndMissingResponseCannotBlockRemainingImages() async {
        let queue = AvatarRequestQueue()
        await queue.replace([7, 8, 9, 7, -1])
        let first = await queue.next(now: 100)
        XCTAssertEqual(first, 7)
        let blocked = await queue.next(now: 105)
        XCTAssertNil(blocked)
        let afterTimeout = await queue.next(now: 111)
        XCTAssertEqual(afterTimeout, 8)
        await queue.received(7) // Late response must not release request 8.
        let stillBlocked = await queue.next(now: 112)
        XCTAssertNil(stillBlocked)
        await queue.received(8)
        let third = await queue.next(now: 113)
        XCTAssertEqual(third, 9)
        await queue.replace([]) // Removing objects cancels pending image reads.
        let removed = await queue.next(now: 114)
        XCTAssertNil(removed)
    }

}
