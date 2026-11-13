import Foundation
import XCTest
@testable import EntrixyCore

final class ReceivedDelegationTests: XCTestCase {
    func testAvailablePartsRejectDuplicateInstalledCodesAndSkipClosedInvitations() throws {
        let group = String(repeating: "B", count: 22), code = String(repeating: "C", count: 22)
        let duplicate = try JSONSerialization.data(withJSONObject: ["grp": group, "state": "new", "parts": [["code": code, "state": "new"], ["code": code, "state": "redeemed"]]])
        XCTAssertThrowsError(try DelegationRedemption.availableCodes(info: duplicate, group: group))
        let closed = try JSONSerialization.data(withJSONObject: ["grp": group, "state": "cancelled", "parts": [["code": code, "state": "expired"]]])
        XCTAssertTrue(try DelegationRedemption.availableCodes(info: closed, group: group).isEmpty)
    }
    func testCompletedRecipientPairSurvivesWithoutKeepingDuplicateSigningSecrets() throws {
        let link = try DelegationLink(server: "controller.invalid", group: String(repeating: "B", count: 22), secret: Data(repeating: 12, count: 32))
        let code = String(repeating: "C", count: 22), nextCode = String(repeating: "D", count: 22)
        func info(_ codes: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["grp": link.group, "state": "new", "parts": codes.map { ["code": $0, "state": "new"] }])
        }
        var pending = try DelegationRedemption(link: link, info: info([code]))
        pending.sent = true; pending.completedCodes = [code]
        var receipt = try ReceivedDelegation(pending: pending)
        let encoded = try JSONEncoder().encode(receipt)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(pending.parts[0].userKey))
        let restored = try JSONDecoder().decode(ReceivedDelegation.self, from: encoded)
        try restored.validate()
        XCTAssertEqual(restored.recipient.privateKey, pending.recipient.privateKey)
        var next = try DelegationRedemption(link: link, info: info([code, nextCode]), recipient: restored.recipient, excludingCodes: [code])
        XCTAssertEqual(next.parts.count, 1)
        XCTAssertEqual(next.parts[0].code, nextCode)
        XCTAssertEqual(next.recipient.publicKey, pending.recipient.publicKey)
        next.sent = true; next.completedCodes = [nextCode]
        try receipt.merge(ReceivedDelegation(pending: next))
        XCTAssertEqual(receipt.parts.count, 2)
        XCTAssertThrowsError(try DelegationRedemption(link: link, info: info([code]), recipient: receipt.recipient, excludingCodes: [code]))
        var stranger = try DelegationRedemption(link: link, info: info([String(repeating: "E", count: 22)]))
        stranger.sent = true; stranger.completedCodes = stranger.parts.map(\.code)
        XCTAssertThrowsError(try receipt.merge(ReceivedDelegation(pending: stranger)))
    }
}
