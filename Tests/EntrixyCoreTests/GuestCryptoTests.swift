import XCTest
@testable import EntrixyCore

final class GuestCryptoTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "client-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testPublishedSigningVectors() throws {
        let f = try fixture()
        let userKey = try XCTUnwrap(f["userKey"] as? String)
        XCTAssertEqual(GuestCrypto.hash(Data(userKey.utf8)), f["keyHash"] as? String)
        XCTAssertEqual(GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: userKey).publicKey.rawRepresentation), f["signPubB64"] as? String)
        for (field, fingerprint) in [("signHeaders_key_bundle_emptyobj", Optional<String>.none),
                                     ("deviceHeaders_key_bundle_emptyobj", f["helloFields_fp"] as? String)] {
            let expected = try XCTUnwrap(f[field] as? [String: String])
            let timestamp = try XCTUnwrap(Int64(try XCTUnwrap(expected["X-Entrixy-Ts"])))
            let actual = try GuestCrypto.headers(userKey: userKey, endpoint: "key_bundle", body: Data("{}".utf8),
                                                 deviceFingerprint: fingerprint, timestamp: timestamp,
                                                 nonce: try XCTUnwrap(expected["X-Entrixy-Nonce"]))
            // Apple CryptoKit may hedge Ed25519 signatures with extra randomness.
            // Preserve the golden signature and verify BOTH it and our output
            // against the published public key; equal signature bytes are not
            // required by the protocol. No fixture value is replaced.
            XCTAssertEqual(actual.filter { $0.key != "X-Entrixy-Sig" },
                           expected.filter { $0.key != "X-Entrixy-Sig" })
            let publishedKey = try XCTUnwrap(f[fingerprint == nil ? "signPubB64" : "devicePub_from_browser"] as? String)
            let publicKey = try GuestCrypto.decodeBase64URL(publishedKey)
            let material = Data("v1.\(expected["X-Entrixy-Key"]!).\(timestamp).\(expected["X-Entrixy-Nonce"]!).key_bundle.44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a".utf8)
            for candidate in [expected["X-Entrixy-Sig"], actual["X-Entrixy-Sig"]] {
                let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(candidate)))
                XCTAssertEqual(signature.count, 64)
                XCTAssertTrue(try GuestCrypto.verify(signature: signature, material: material, publicKey: publicKey))
                XCTAssertFalse(try GuestCrypto.verify(signature: signature, material: material + Data("tampered".utf8), publicKey: publicKey))
            }
        }
    }

    func testPublishedEncryptedEnvelopeAndWrongKeyRejection() throws {
        let f = try fixture()
        let aes = try XCTUnwrap(f["aes"] as? [String: String])
        let key = Data((0..<32).map { UInt8($0) })
        let envelope = try XCTUnwrap(aes["blob"])
        XCTAssertEqual(String(data: try GuestCrypto.decrypt(key: key, envelope: envelope), encoding: .utf8), aes["plaintext"])
        XCTAssertThrowsError(try GuestCrypto.decrypt(key: Data(repeating: 255, count: 32), envelope: envelope))
        XCTAssertThrowsError(try GuestCrypto.decrypt(key: key, envelope: "v2:AAAA"))
    }
}
