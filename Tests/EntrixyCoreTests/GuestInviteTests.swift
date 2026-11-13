import XCTest
@testable import EntrixyCore

final class GuestInviteTests: XCTestCase {
    private let blob = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43)

    func testFullLinkPreservesExplicitServerAndKey() throws {
        let key = try GuestInvite.parse("https://entrixy.com/key#\(blob)&h=keys.example.org:8443")
        XCTAssertEqual(key.server, "keys.example.org:8443")
        XCTAssertEqual(key.userKey, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX")
        XCTAssertEqual(key.bundleKey.count, 32)
        XCTAssertFalse(key.id.contains(key.userKey))
    }

    func testBareKeyUsesExplicitDefaultServer() throws {
        XCTAssertEqual(try GuestInvite.parse(blob, defaultServer: "https://ENTRIXY.com/").server, "entrixy.com")
    }

    func testMalformedOrPartialLinkIsRejected() {
        for input in ["", "https://entrixy.com/key#", "http://entrixy.com/key#\(blob)", String(blob.prefix(32)), blob + "x"] {
            XCTAssertThrowsError(try GuestInvite.parse(input), input)
        }
    }

    func testServerCannotCarryCredentialsPathOrQuery() {
        for server in ["http://example.com", "user:password@example.com", "example.com/other", "example.com?token=secret", "example.com#key", "", "example.com:0", "example.com:65536"] {
            XCTAssertThrowsError(try GuestInvite.normalizeServer(server), server)
        }
    }
}
