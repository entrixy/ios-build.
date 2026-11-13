import Foundation
import XCTest
@testable import EntrixyCore

final class DelegationProofTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.module.url(forResource: "delegation-proof-v1", withExtension: "json", subdirectory: "Fixtures")!)) as! [String: Any]
    }
    func testIndependentMACAndVouchSignatures() throws {
        let f = try fixture(), secret = try GuestCrypto.decodeBase64URL(f["secret"] as! String)
        let group = f["group"] as! String, sp = f["sign_public"] as! String, gp = f["guest_public"] as! String
        XCTAssertEqual(try DelegationProof.passMAC(secret: secret, group: group, signPublic: sp, guestPublic: gp), f["mac"] as? String)
        let publicKey = try GuestCrypto.decodeBase64URL(f["parent_public"] as! String)
        XCTAssertTrue(try DelegationProof.verifyVouch(f["vouch"] as! String, parentPublic: publicKey, server: "controller.invalid", childID: 17, signPublic: sp, guestPublic: gp))
        let generated = try DelegationProof.vouch(userKey: f["user_key"] as! String, server: "controller.invalid", childID: 17, signPublic: sp, guestPublic: gp)
        // Apple CryptoKit can produce randomized valid Ed25519 signatures.
        XCTAssertTrue(try DelegationProof.verifyVouch(generated, parentPublic: publicKey, server: "controller.invalid", childID: 17, signPublic: sp, guestPublic: gp))
        XCTAssertFalse(try DelegationProof.verifyVouch(generated, parentPublic: publicKey, server: "other.invalid", childID: 17, signPublic: sp, guestPublic: gp))
        XCTAssertFalse(try DelegationProof.verifyVouch(generated, parentPublic: publicKey, server: "controller.invalid", childID: 18, signPublic: sp, guestPublic: gp))
        XCTAssertFalse(try DelegationProof.checkMAC(f["mac"] as! String, secret: secret, group: String(repeating: "A", count: 22), signPublic: sp, guestPublic: gp))
        XCTAssertFalse(try DelegationProof.checkMAC(String(repeating: "0", count: 64), secret: secret, group: group, signPublic: sp, guestPublic: gp))
        XCTAssertFalse(try DelegationProof.checkMAC("invalid", secret: secret, group: group, signPublic: sp, guestPublic: gp))
    }
    func testStrictDelegationLinkAndPublicKeyValidation() throws {
        let f = try fixture(), secret = try GuestCrypto.decodeBase64URL(f["secret"] as! String)
        let link = try DelegationLink(server: "controller.invalid", group: f["group"] as! String, secret: secret)
        XCTAssertEqual(try DelegationLink.parse(link.url), link)
        for bad in [link.url.replacingOccurrences(of: "https:", with: "http:"), link.url + "=", link.url.replacingOccurrences(of: "/i/", with: "/key/"), link.url.replacingOccurrences(of: "#", with: "?secret="), link.url.replacingOccurrences(of: "controller.invalid", with: "user@controller.invalid")] {
            XCTAssertThrowsError(try DelegationLink.parse(bad))
        }
        XCTAssertThrowsError(try DelegationProof.passMAC(secret: secret, group: link.group, signPublic: f["sign_public"] as! String, guestPublic: GuestCrypto.base64URL(Data(repeating: 0, count: 91))))
        XCTAssertThrowsError(try DelegationProof.passMAC(secret: Data(), group: link.group, signPublic: f["sign_public"] as! String, guestPublic: f["guest_public"] as! String))
    }
}
