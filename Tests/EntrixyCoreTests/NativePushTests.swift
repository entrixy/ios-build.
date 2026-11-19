import XCTest
@testable import EntrixyCore

final class NativePushTests: XCTestCase {
    func testPushAcceptsOnlyBoundedDeliveryHintsAndPreservesNormalizedServerIdentity() throws {
        let hash = String(repeating:"a",count:64)
        for kind in ["message","share_message","share_part"] {
            let value = try NativePushEvent(payload:["entrixy":["type":kind,"server":"https://ENTRIXY.com/","hash":hash]])
            XCTAssertEqual(value.server,"entrixy.com"); XCTAssertEqual(value.keyHash,hash); try value.validate()
        }
        for kind in ["fire","open","grant","call",""] {
            XCTAssertThrowsError(try NativePushEvent(payload:["entrixy":["type":kind,"server":"entrixy.com","hash":hash]]))
        }
        for server in ["http://entrixy.com","https://entrixy.com/path","https://user:secret@entrixy.com"] {
            XCTAssertThrowsError(try NativePushEvent(payload:["entrixy":["type":"message","server":server,"hash":hash]]))
        }
        XCTAssertThrowsError(try NativePushEvent(payload:["entrixy":["type":"message","server":"entrixy.com","hash":String(repeating:"a",count:65)]]))
    }
    func testAPNsTokensAreOpaqueBoundedHexAndCannotChooseTransportOrCarrySecrets() throws {
        for count in [32,64,80,512] {
            let value = try NativePushRegistration(token:String(repeating:"b",count:count),environment:.production)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with:value.data()) as? [String:String])
            XCTAssertEqual(Set(body.keys),["token","environment"])
            XCTAssertEqual(body["environment"],"production")
        }
        for token in ["",String(repeating:"a",count:31),String(repeating:"a",count:513),String(repeating:"A",count:64),"https://provider.invalid/token"] {
            XCTAssertThrowsError(try NativePushRegistration(token:token,environment:.sandbox))
        }
        let decoded = try JSONDecoder().decode(NativePushRegistration.self,from:Data(#"{"token":"https://provider.invalid","environment":"sandbox"}"#.utf8))
        XCTAssertThrowsError(try decoded.data())
    }
}
