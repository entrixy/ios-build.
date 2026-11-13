import Foundation
import XCTest
@testable import EntrixyCore

final class GuestMessageCryptoTests: XCTestCase {
    func testIndependentPythonRootAndSealedMessageVectors() throws {
        let url = Bundle.module.url(forResource: "message-v1", withExtension: "json", subdirectory: "Fixtures")!
        let f = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        let key = try GuestCrypto.decodeBase64URL(f["root_key"]!)
        let recipient = BundleKeySeal.Recipient(privateKey: f["recipient_private"]!, publicKey: f["recipient_public"]!)
        XCTAssertEqual(try GuestMessageCrypto.open(f["root_cipher"]!, bundleKey: key), f["text"])
        XCTAssertEqual(try GuestMessageCrypto.open(f["passed_cipher"]!, bundleKey: key, recipient: recipient), f["text"])
        XCTAssertEqual(GuestMessageCrypto.acknowledgementHash(f["passed_cipher"]!), f["ack_hash"])
    }
    func testRootAndPassedMessageEnvelopesRequireTheIntendedKey() throws {
        let text = "Здравствуйте! Откройте приложение, когда будет удобно.", key = Data(repeating: 31, count: 32)
        let root = try GuestMessageCrypto.seal(text, bundleKey: key)
        XCTAssertEqual(try GuestMessageCrypto.open(root, bundleKey: key), text)
        XCTAssertThrowsError(try GuestMessageCrypto.open(root, bundleKey: Data(repeating: 32, count: 32)))
        let recipient = BundleKeySeal.makeRecipient(), passed = try GuestMessageCrypto.seal(text, recipientPublic: recipient.publicKey)
        XCTAssertTrue(passed.contains("|"))
        XCTAssertEqual(try GuestMessageCrypto.open(passed, bundleKey: Data(repeating: 0, count: 32), recipient: recipient), text)
        XCTAssertThrowsError(try GuestMessageCrypto.open(passed, bundleKey: key))
        XCTAssertThrowsError(try GuestMessageCrypto.open(passed, bundleKey: key, recipient: BundleKeySeal.makeRecipient()))
        XCTAssertThrowsError(try GuestMessageCrypto.open(passed + "|extra", bundleKey: key, recipient: recipient))
        XCTAssertThrowsError(try GuestMessageCrypto.seal(String(repeating: "A", count: 501), bundleKey: key))
        XCTAssertThrowsError(try GuestMessageCrypto.seal(" \n", bundleKey: key))
        XCTAssertNotEqual(try GuestMessageCrypto.seal(text, recipientPublic: recipient.publicKey), passed)
    }
    func testAckHashMatchesAndroidSHA256PrefixAndMessageIsNotAnActionEvent() throws {
        // Python hashlib.sha256(b'v1:public-test-cipher').hexdigest()[:24]
        XCTAssertEqual(GuestMessageCrypto.acknowledgementHash("v1:public-test-cipher"), "d9ddcb50ff4d6f68324a0f06")
        let bytes = Data(#"{"type":"message","msg_id":17,"cipher":"v1:public-test-cipher"}"#.utf8)
        guard case .message(let cipher) = try GuestEvent.decode(bytes) else { return XCTFail("Message must remain separate from action history") }
        XCTAssertEqual(cipher, "v1:public-test-cipher")
    }
}
