import Foundation
import XCTest
@testable import EntrixyCore

final class OwnerObjectTests: XCTestCase {
    private let master = Data(repeating: 42, count: 32)
    private func draft() throws -> OwnerObject {
        try OwnerObject(masterKey: master, label: "Тестовые ворота", kind: "call", phone: "+79990000000")
    }
    private func snapshot(_ rows: [[String: Any]]) throws -> OwnerSnapshot {
        try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": rows, "keys": []]))
    }

    func testPresentationEditKeepsObjectSecretsAndUnrelatedMetadata() throws {
        var object = try draft()
        object.numberID = 7; object.pending = nil; object.revision = 100; object.available = true
        let wrapped = object.wrappedKey, phone = object.localPhone
        try object.updatePresentation(label: "Калитка", preset: 6, masterKey: master)
        let metadata = try object.metadata(masterKey: master)
        XCTAssertEqual(metadata["label"] as? String, "Калитка")
        XCTAssertEqual(metadata["avatar_type"] as? String, "preset:6")
        XCTAssertEqual(object.wrappedKey, wrapped)
        XCTAssertEqual(object.localPhone, phone)
        XCTAssertEqual(object.pending, .update)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: object.request()) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["id", "data_cipher", "data_cipher_ts_check"])
        XCTAssertFalse(String(decoding: try object.request(), as: UTF8.self).contains("Калитка"))
        XCTAssertThrowsError(try object.updatePresentation(label: "Снова", preset: 8, masterKey: master))
    }

    func testPrivateMetadataEncryptedAndKeyWrappedBeforeRequest() throws {
        let object = try draft()
        let body = try JSONSerialization.jsonObject(with: object.request()) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["type", "data_cipher"])
        XCTAssertEqual(body["type"] as? String, "call")
        XCTAssertEqual(object.localPhone, "+79990000000")
        XCTAssertNil(try object.metadata(masterKey: master)["phone"])
        XCTAssertThrowsError(try object.metadata(masterKey: Data(count: 32)))
        let encoded = try JSONEncoder().encode(object)
        let decoded = try JSONDecoder().decode(OwnerObject.self, from: encoded)
        XCTAssertEqual(object, decoded)
        try decoded.validate(masterKey: master)
    }

    func testLostCreateReplyRecoveredOnlyByExactCipherWithoutReplay() throws {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "call", phone: "+79990000000")
        object.sent = true
        owner.objects = [object]
        try owner.reconcileObjects(snapshot([]))
        XCTAssertTrue(owner.objects![0].sent)
        XCTAssertEqual(owner.objects![0].pending, .create)
        let row: [String: Any] = ["id": 7, "type": "call", "data_cipher": object.cipher, "data_cipher_revision": 100]
        try owner.reconcileObjects(snapshot([row]))
        XCTAssertEqual(owner.objects![0].numberID, 7)
        XCTAssertNil(owner.objects![0].pending)
        XCTAssertEqual(owner.objects![0].revision, 100)
        try owner.validate()
    }

    func testDuplicateCipherReplyIsRejectedWithoutReplacingSavedDraft() throws {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "call", phone: "+79990000000")
        object.sent = true; owner.objects = [object]
        XCTAssertThrowsError(try owner.reconcileObjects(snapshot([
            ["id": 1, "type": "call", "data_cipher": object.cipher], ["id": 2, "type": "call", "data_cipher": object.cipher]])))
        XCTAssertEqual(owner.objects, [object])
    }

    func testRenameRetainsUnknownMetadataAndRequiresKnownRevision() throws {
        var object = try draft()
        object.numberID = 7; object.pending = nil
        XCTAssertThrowsError(try object.rename("Новое имя", masterKey: master))
        object.revision = 100
        let key = try GuestCrypto.decrypt(key: master, envelope: object.wrappedKey)
        var metadata = try object.metadata(masterKey: master)
        metadata["future_field"] = ["kept": true]
        object.cipher = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: metadata))
        try object.rename("Новое имя", masterKey: master)
        let updated = try object.metadata(masterKey: master)
        XCTAssertEqual(updated["label"] as? String, "Новое имя")
        XCTAssertEqual((updated["future_field"] as? [String: Bool])?["kept"], true)
        let body = try JSONSerialization.jsonObject(with: object.request()) as! [String: Any]
        XCTAssertEqual(body["data_cipher_ts_check"] as? Int, 100)
        XCTAssertEqual(body["id"] as? Int, 7)
        XCTAssertNil(body["label"])
    }

    func testClaimAndCreateAreSeparateDurableSteps() throws {
        var object = try OwnerObject(masterKey: master, label: "Контроллер", kind: "device", claimCode: " a1b2c3d4 ")
        XCTAssertEqual(object.pending, .claim)
        XCTAssertThrowsError(try object.acceptClaim(deviceID: 9))
        object.sent = true
        try object.acceptClaim(deviceID: 9)
        XCTAssertEqual(object.pending, .create)
        XCTAssertFalse(object.sent)
        XCTAssertNil(object.claimCode)
        let body = try JSONSerialization.jsonObject(with: object.request()) as! [String: Any]
        XCTAssertEqual(body["device_id_ref"] as? Int, 9)
        XCTAssertNil(body["claim_code"])
    }

    func testWebhookRoutingIsExplicitAndOtherMetadataStaysEncrypted() throws {
        let object = try OwnerObject(masterKey: master, label: "Запрос", kind: "webhook", url: "https://controller.invalid/open", secret: "public-fixture")
        let body = try JSONSerialization.jsonObject(with: object.request()) as! [String: Any]
        XCTAssertEqual(body["webhook_mode"] as? String, "server")
        XCTAssertEqual(body["webhook_secret"] as? String, "public-fixture")
        XCTAssertNil(body["label"])
        XCTAssertThrowsError(try OwnerObject(masterKey: master, label: "Запрос", kind: "webhook", url: "http://controller.invalid", secret: "secret"))
        XCTAssertThrowsError(try OwnerObject(masterKey: master, label: "Ворота", kind: "device"))
    }

    func testConfirmedDeleteAndUpdateReconcileWithoutNewRequests() throws {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "call", phone: "+79990000000")
        object.numberID = 7; object.revision = 100; object.pending = nil
        try object.rename("Новые ворота", masterKey: owner.masterKey)
        object.sent = true; owner.objects = [object]
        try owner.reconcileObjects(snapshot([["id": 7, "type": "call", "data_cipher": object.cipher, "data_cipher_revision": 101]]))
        XCTAssertNil(owner.objects![0].pending)
        XCTAssertEqual(owner.objects![0].revision, 101)
        owner.objects![0].pending = .delete; owner.objects![0].sent = true
        try owner.reconcileObjects(snapshot([]))
        XCTAssertTrue(owner.objects!.isEmpty)
    }

    func testInvalidRevisionAndBooleanReplyIDAreRejected() throws {
        XCTAssertThrowsError(try snapshot([["id": 1, "type": "call", "data_cipher_revision": true]]))
        XCTAssertThrowsError(try snapshot([["id": 1, "type": "call", "data_cipher_revision": -1]]))
        XCTAssertThrowsError(try OwnerObject.replyID(NSNumber(value: true)))
        XCTAssertThrowsError(try OwnerObject.replyID(0))
        XCTAssertEqual(try OwnerObject.replyID(9), 9)
    }
}
