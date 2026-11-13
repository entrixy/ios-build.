import Foundation
import XCTest
@testable import EntrixyCore

final class DelegationRedemptionTests: XCTestCase {
    private func pending() throws -> DelegationRedemption {
        let link = try DelegationLink(server: "controller.invalid", group: String(repeating: "A", count: 22), secret: Data(repeating: 12, count: 32))
        let info = try JSONSerialization.data(withJSONObject: ["grp": link.group, "state": "new", "parts": [["code": String(repeating: "B", count: 22), "state": "new"], ["code": String(repeating: "C", count: 22), "state": "expired"]]])
        return try DelegationRedemption(link: link, info: info)
    }
    func testDurableRecipientUsesIdenticalKeysAndRequestAfterRelaunch() throws {
        let original = try pending(), fp = String(repeating: "a", count: 64)
        let restored = try JSONDecoder().decode(DelegationRedemption.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.parts.count, 1)
        XCTAssertEqual(try original.request(fingerprint: fp), try restored.request(fingerprint: fp))
        let key = Data(repeating: 31, count: 32)
        let sealed = try BundleKeySeal.seal(key, recipientPublicKey: original.recipient.publicKey)
        let invite = try restored.invitation(part: restored.parts[0], keyCipher: sealed)
        XCTAssertEqual(invite.bundleKey, key)
        XCTAssertEqual(invite.userKey, original.parts[0].userKey)
        XCTAssertEqual(invite.server, "controller.invalid")
        let wrong = try BundleKeySeal.seal(key, recipientPublicKey: BundleKeySeal.makeRecipient().publicKey)
        XCTAssertThrowsError(try restored.invitation(part: restored.parts[0], keyCipher: wrong))
    }
    func testInfoForOtherGroupOrDuplicatePartsIsRejected() throws {
        let original = try pending()
        for parts in [[], [["code": String(repeating: "B", count: 22), "state": "new"], ["code": String(repeating: "B", count: 22), "state": "new"]]] as [[[String: String]]] {
            let info = try JSONSerialization.data(withJSONObject: ["grp": original.link.group, "state": "new", "parts": parts])
            XCTAssertThrowsError(try DelegationRedemption(link: original.link, info: info))
        }
        let info = try JSONSerialization.data(withJSONObject: ["grp": String(repeating: "Z", count: 22), "state": "new", "parts": [["code": String(repeating: "B", count: 22), "state": "new"]]])
        XCTAssertThrowsError(try DelegationRedemption(link: original.link, info: info))
    }
}
