import XCTest
@testable import EntrixyCore

final class DeviceClaimLinkTests: XCTestCase {
    func testHTTPSClaimUsesFactoryOriginAndPortRatherThanSelectedHostOrQueryOverride() throws {
        let claim = try DeviceClaimLink.parse(URL(string:"https://factory.example:8443/claim?c=a1-b2%20c3d4&h=other.example")!,selectedServer:"selected.example")
        XCTAssertEqual(claim.server,"factory.example:8443"); XCTAssertEqual(claim.code,"A1B2C3D4")
    }
    func testCustomSchemeUsesSelectedServerWithoutCreatingDefaultServerAssumption() throws {
        let claim = try DeviceClaimLink.parse(URL(string:"entrixy://claim?c=1234-abcd&h=other.example")!,selectedServer:"Private.Example:9443")
        XCTAssertEqual(claim.server,"private.example:9443"); XCTAssertEqual(claim.code,"1234ABCD")
    }
    func testMalformedAmbiguousOrNonClaimLinksAreRejected() {
        for raw in ["https://factory.example/claim?c=A1&c=B2","entrixy://claim?c=", "entrixy://claim?c=xyz", "https://user:pass@factory.example/claim?c=A1", "https://factory.example/claim?c=A1#B2", "http://factory.example/claim?c=A1", "entrixy://claim:443?c=A1", "entrixy://claim/extra?c=A1", "https://factory.example/key?c=A1"] {
            XCTAssertThrowsError(try DeviceClaimLink.parse(URL(string:raw)!,selectedServer:"selected.example"),raw)
        }
    }
    func testCodeAndLinkSizeAreBoundedAndNonASCIIHexIsNotAccepted() {
        for code in [String(repeating:"A",count:129),String(repeating:"-",count:5000),"ＡＢＣＤ"] {
            let url = URL(string:"entrixy://claim?c="+code.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed)!)!
            XCTAssertThrowsError(try DeviceClaimLink.parse(url,selectedServer:"selected.example"))
        }
    }
    func testClaimRecognitionDoesNotStealKeyOrCompanyLinks() {
        for raw in ["entrixy://key#A1","entrixy://company?code=A1","https://factory.example/c/A1","https://factory.example/key#A1"] {
            XCTAssertFalse(DeviceClaimLink.recognizes(URL(string:raw)!))
        }
        XCTAssertTrue(DeviceClaimLink.recognizes(URL(string:"entrixy://claim?c=A1")!))
    }
}
