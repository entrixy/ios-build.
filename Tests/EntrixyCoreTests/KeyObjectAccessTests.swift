import Foundation
import XCTest
@testable import EntrixyCore

final class KeyObjectAccessTests: XCTestCase {
    func testBoundsAndStrictSnapshotTypes() throws {
        XCTAssertThrowsError(try KeyObjectAccess(depth: 6))
        XCTAssertThrowsError(try KeyObjectAccess(pool: 0))
        XCTAssertThrowsError(try KeyObjectAccess(pool: 51))
        for value: Any in [true, -1, 1.5, 6] {
            XCTAssertThrowsError(try KeyObjectAccess.decode([["id": 7, "native_only": 0, "depth": value, "pool": 3]]))
        }
        let access = try KeyObjectAccess(depth: 5, pool: 50)
        XCTAssertEqual(try KeyObjectAccess.decode([access.json(id: 7)])?["7"], access)
        XCTAssertThrowsError(try KeyObjectAccess.decode([access.json(id: 7), access.json(id: 7)]))
    }
    func testExplicitOwnerRightsAreConfirmedOnlyWithExactSettingsAndUnchangedLink() throws {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "webhook", url: "https://actuator.invalid/open", secret: "test-only")
        object.numberID = 7; object.pending = nil; object.revision = 100; owner.objects = [object]
        let settings = try KeyObjectAccess(depth: 2, pool: 8)
        var key = try OwnerIssuedKey(owner: owner, label: "Друг", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true, access: [7: settings])
        let body = try JSONSerialization.jsonObject(with: key.request(masterKey: owner.masterKey)) as! [String: Any]
        XCTAssertEqual(body["delegate_depth"] as? Int, 2)
        XCTAssertEqual(try KeyObjectAccess.decode(body["objects"])?["7"], settings)
        let pair = try key.secrets(masterKey: owner.masterKey)
        key.sent = true; owner.issuedKeys = [key]
        func snapshot(_ settings: KeyObjectAccess, cipher: String) throws -> OwnerSnapshot {
            try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [], "keys": [["id": 17, "mode": "auto", "enabled": 1, "sign_pub": body["sign_pub"]!, "number_ids": [7], "bundle_cipher": cipher, "objects": [settings.json(id: 7)]]]]))
        }
        XCTAssertThrowsError(try owner.reconcileIssuedKeys(snapshot(KeyObjectAccess(depth: 3, pool: 8), cipher: key.bundleCipher)))
        try owner.reconcileIssuedKeys(snapshot(settings, cipher: key.bundleCipher))
        key = owner.issuedKeys![0]
        XCTAssertNil(key.pending)
        XCTAssertEqual(key.grantedAccess?["7"], settings)
        let oldLink = try key.link(server: owner.server, masterKey: owner.masterKey)
        let tighter = try KeyObjectAccess(depth: 0, pool: 1)
        try key.edit(owner: owner, label: key.label, numberIDs: [7], welcome: "", access: [7: tighter])
        key.sent = true; owner.issuedKeys = [key]
        try owner.reconcileIssuedKeys(snapshot(settings, cipher: key.bundleCipher))
        XCTAssertEqual(owner.issuedKeys![0].pending, .keyEdit)
        XCTAssertEqual(owner.issuedKeys![0].grantedAccess?["7"], settings)
        try owner.reconcileIssuedKeys(snapshot(tighter, cipher: key.bundleCipher))
        key = owner.issuedKeys![0]
        XCTAssertNil(key.pending)
        XCTAssertEqual(key.grantedAccess?["7"], tighter)
        XCTAssertEqual(try key.secrets(masterKey: owner.masterKey).userKey, pair.userKey)
        XCTAssertEqual(try key.link(server: owner.server, masterKey: owner.masterKey), oldLink)
    }
}
