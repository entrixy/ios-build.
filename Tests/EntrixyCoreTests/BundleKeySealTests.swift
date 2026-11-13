import Foundation
import XCTest
@testable import EntrixyCore

final class BundleKeySealTests: XCTestCase {
    func testIndependentAndroidFormatEnvelope() throws {
        let url = Bundle.module.url(forResource: "bundle-key-seal-v1", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let recipient = try JSONDecoder().decode(BundleKeySeal.Recipient.self, from: data)
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(try BundleKeySeal.open(fixture["envelope"]!, recipient: recipient),
                       try GuestCrypto.decodeBase64URL(fixture["bundleKey"]!))
    }

    func testGeneratedRecipientRoundTripAndRandomization() throws {
        let recipient = BundleKeySeal.makeRecipient()
        let key = Data(0..<32)
        let first = try BundleKeySeal.seal(key, recipientPublicKey: recipient.publicKey)
        let second = try BundleKeySeal.seal(key, recipientPublicKey: recipient.publicKey)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try BundleKeySeal.open(first, recipient: recipient), key)
        XCTAssertEqual(try BundleKeySeal.open(second, recipient: recipient), key)
        XCTAssertThrowsError(try BundleKeySeal.open(first, recipient: BundleKeySeal.makeRecipient()))
    }

    func testRejectMalformedTamperedAndWrongLengthKeys() throws {
        let recipient = BundleKeySeal.makeRecipient()
        let sealed = try BundleKeySeal.seal(Data(repeating: 3, count: 32), recipientPublicKey: recipient.publicKey)
        let parts = sealed.dropFirst(3).split(separator: ".")
        var bytes = try GuestCrypto.decodeBase64URL(String(parts[1]))
        bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try BundleKeySeal.open("v1:" + parts[0] + "." + GuestCrypto.base64URL(bytes), recipient: recipient))
        for malformed in ["", String(sealed.dropFirst(3)), "v2:" + sealed.dropFirst(3), "v1:.", sealed + ".extra"] {
            XCTAssertThrowsError(try BundleKeySeal.open(malformed, recipient: recipient))
        }
        XCTAssertThrowsError(try BundleKeySeal.seal(Data(count: 31), recipientPublicKey: recipient.publicKey))
        XCTAssertThrowsError(try BundleKeySeal.seal(Data(count: 32), recipientPublicKey: "invalid"))
        let other = BundleKeySeal.makeRecipient()
        let mismatch = Data("{\"privateKey\":\"\(recipient.privateKey)\",\"publicKey\":\"\(other.publicKey)\"}".utf8)
        XCTAssertThrowsError(try BundleKeySeal.open(sealed, recipient: JSONDecoder().decode(BundleKeySeal.Recipient.self, from: mismatch)))
    }
}
