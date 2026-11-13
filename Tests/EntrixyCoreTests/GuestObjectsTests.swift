import Foundation
import XCTest
@testable import EntrixyCore

final class GuestObjectsTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testOldObjectKeyStillDecryptsDuringRotation() throws {
        let old = Data(repeating: 12, count: 32)
        let current = Data(repeating: 13, count: 32)
        let cipher = try GuestCrypto.encrypt(key: old, plaintext: json(["label": "Калитка", "avatar_type": "preset:5"]))
        let bundle = try json(["obj_keys": ["7": GuestCrypto.base64URL(current)], "obj_keys_prev": ["7": GuestCrypto.base64URL(old)]])
        let snapshot = try json(["numbers": [["id": 7, "type": "device", "data_cipher": cipher]]])
        let object = try GuestObjects.decode(bundle: bundle, snapshot: snapshot).first
        XCTAssertEqual(object?.label, "Калитка")
        XCTAssertEqual(object?.avatarType, "preset:5")
    }

    func testServerPlaintextLabelDoesNotReplaceEncryptedOwnerData() throws {
        let bundle = try json(["obj_keys": [:]])
        let snapshot = try json(["numbers": [["id": 7, "type": "device", "label": "Forged by server", "avatar_type": "preset:7", "data_cipher": "v1:AAAA"]]])
        let object = try GuestObjects.decode(bundle: bundle, snapshot: snapshot).first
        XCTAssertEqual(object?.label, "Название недоступно")
        XCTAssertNil(object?.avatarType)
    }

    func testUnsupportedNetworkRestrictionDoesNotSilentlyDisappear() throws {
        XCTAssertThrowsError(try GuestObjects.decode(bundle: json(["net_block": [["s": "Private"]]]), snapshot: json(["numbers": []])))
    }
}
