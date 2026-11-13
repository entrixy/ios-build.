import Foundation
import XCTest
@testable import EntrixyCore

final class BackupEnvelopeTests: XCTestCase {
    private func fixture() throws -> [String: String] {
        let url = Bundle.module.url(forResource: "backup-v1", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
    }
    func testIndependentAndroidFormatWithUnicodePassword() throws {
        let f = try fixture()
        let blob = Data(base64Encoded: f["blob"]!)!
        XCTAssertEqual(try BackupEnvelope.open(blob, password: f["password"]!), Data(f["payload"]!.utf8))
        XCTAssertThrowsError(try BackupEnvelope.open(blob, password: "wrong password"))
    }
    func testExportUsesFreshSaltNonceAndAuthenticatesTheHeader() throws {
        let payload = Data("private test state".utf8), password = "test-password"
        let first = try BackupEnvelope.seal(payload, password: password)
        let second = try BackupEnvelope.seal(payload, password: password)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.prefix(8), Data("ENTRIXY1".utf8))
        XCTAssertEqual(try BackupEnvelope.open(first, password: password), payload)
        var modified = first; modified[14] ^= 1
        XCTAssertThrowsError(try BackupEnvelope.open(modified, password: password))
        modified = first; modified[30] ^= 1
        XCTAssertThrowsError(try BackupEnvelope.open(modified, password: password))
    }
    func testMalformedAndUnboundedKDFInputsAreRejected() throws {
        let f = try fixture(), blob = Data(base64Encoded: f["blob"]!)!
        for index in [0,8,9] {
            var changed = blob; changed[index] ^= 255
            XCTAssertThrowsError(try BackupEnvelope.open(changed, password: f["password"]!))
        }
        var expensive = blob
        for i in 10..<14 { expensive[i] = 255 }
        XCTAssertThrowsError(try BackupEnvelope.open(expensive, password: f["password"]!))
        XCTAssertThrowsError(try BackupEnvelope.open(Data(), password: "anything"))
        XCTAssertThrowsError(try BackupEnvelope.seal(Data(), password: "short"))
    }
}
