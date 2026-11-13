import Foundation
import XCTest
@testable import EntrixyCore

final class BLECommandSessionTests: XCTestCase {
    private func grant() throws -> BLEGuestGrant {
        let token = try BLECrypto.token(guestID: 513, validUntil: 1000)
        return try BLEGuestGrant(row: ["id": 7, "did": -1, "token": token.base64EncodedString(), "sig": Data(count: 16).base64EncodedString(), "gkey": Data(repeating: 8, count: 32).base64EncodedString(), "valid_until": 1000])
    }
    func testOneWriteOnlyAndGattWriteDoesNotBecomePhysicalSuccess() throws {
        var command = try BLECommandSession(credential: .owner(Data(repeating: 8, count: 32)), now: 10, epoch: 900)
        XCTAssertThrowsError(try command.consume(now: 10, epoch: 900))
        try command.prepare(nonce: Data(repeating: 9, count: 8), now: 11, epoch: 901)
        XCTAssertNotNil(command.proofHash)
        XCTAssertEqual(try command.consume(now: 12, epoch: 902).count, 24)
        XCTAssertEqual(command.phase, .consumed)
        XCTAssertNil(command.result)
        XCTAssertThrowsError(try command.consume(now: 12, epoch: 902))
        XCTAssertNil(command.receive(0x10), "A TIME result must never become an opening result")
        XCTAssertNil(command.receive(0x40), "A revoke receipt must never become an opening result")
        XCTAssertEqual(command.receive(0x32), .opening)
        XCTAssertNil(command.receive(0), "A late duplicate cannot replace the first terminal result")
    }
    func testExpiryIsRecheckedAndClockRollbackCannotReviveAnExpiredPreparedCommand() throws {
        let grant = try grant()
        XCTAssertEqual(grant.deviceID, UInt32.max)
        var command = try BLECommandSession(credential: .guest(grant), now: 10, epoch: 999)
        try command.prepare(nonce: Data(count: 8), now: 10, epoch: 999)
        XCTAssertThrowsError(try command.consume(now: 11, epoch: 1001))
        XCTAssertThrowsError(try command.consume(now: 12, epoch: 999))
        XCTAssertThrowsError(try BLECommandSession(credential: .guest(grant), now: 0, epoch: 1001))
    }
    func testFreshChallengeDeadlineCancellationAndAllControllerFailureResults() throws {
        var command = try BLECommandSession(credential: .guest(grant()), now: 0, epoch: 900)
        try command.prepare(nonce: Data(count: 8), now: 1, epoch: 901)
        XCTAssertThrowsError(try command.consume(now: 7, epoch: 907))
        command.cancel()
        XCTAssertThrowsError(try command.consume(now: 2, epoch: 902))
        for code: UInt8 in 1...8 {
            var attempt = try BLECommandSession(credential: .owner(Data(count: 32)), now: 0, epoch: 900)
            try attempt.prepare(nonce: Data(count: 8), now: 1, epoch: 901)
            _ = try attempt.consume(now: 2, epoch: 902)
            XCTAssertEqual(attempt.receive(code)?.succeeded, false)
        }
    }
    func testBundleGrantRejectsMismatchedExpiryWrongPermissionsAndBooleanDeviceID() throws {
        let grant = try grant()
        var row: [String: Any] = ["id": 7, "did": 7, "token": grant.token.base64EncodedString(), "sig": grant.ownerSignature.base64EncodedString(), "gkey": grant.guestKey.base64EncodedString(), "valid_until": 999]
        XCTAssertThrowsError(try BLEGuestGrant(row: row))
        row["valid_until"] = 1000; row["did"] = true
        XCTAssertThrowsError(try BLEGuestGrant(row: row))
        row["did"] = 7; var token = grant.token; token[6] = 0; row["token"] = token.base64EncodedString()
        XCTAssertThrowsError(try BLEGuestGrant(row: row))
    }
}
