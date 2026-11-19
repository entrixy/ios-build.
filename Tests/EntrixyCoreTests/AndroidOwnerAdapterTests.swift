import XCTest
@testable import EntrixyCore

final class AndroidOwnerAdapterTests: XCTestCase {
    func testPendingAndroidRotationPreservesExactGenerationAndCipherWithoutReplacingKeys() throws {
        let master = Data(repeating: 7, count: 32), old = Data(repeating: 8, count: 32), fresh = Data(repeating: 9, count: 32)
        let clear = Data(#"{"label":"Ворота","avatar_type":"preset:1"}"#.utf8)
        let oldCipher = try GuestCrypto.encrypt(key: old, plaintext: clear)
        let nextCipher = try GuestCrypto.encrypt(key: fresh, plaintext: clear)
        let previous = try GuestCrypto.encrypt(key: master, plaintext: old), current = try GuestCrypto.encrypt(key: master, plaintext: fresh)
        let values = ["e2ee_master_key":GuestCrypto.base64URL(master), "backup_server_host":"owner.invalid",
            "owner_accounts":try json([["host":"owner.invalid","id":String(repeating:"a",count:32),"secret":String(repeating:"b",count:64)]]),
            "host_numbers":try json([["id":7,"host":"owner.invalid","type":"call","phone":"+15550000001"]] as [[String:Any]]),
            "e2ee_obj_7":current,"e2ee_obj_prev_7":previous,"e2ee_obj_blob_7":oldCipher,"pending_rotated_cipher_7":nextCipher]
        let source = try document(values, integers:["e2ee_obj_epoch_7":5])
        let owner = try XCTUnwrap(AndroidOwnerAdapter.owners(from:source).first)
        let object = try XCTUnwrap(owner.objects?.first)
        XCTAssertEqual(object.wrappedKey,previous); XCTAssertEqual(object.cipher,oldCipher)
        XCTAssertEqual(object.keyEpoch,4); XCTAssertEqual(object.keyRotation?.epoch,5)
        XCTAssertEqual(object.keyRotation?.wrappedKey,current); XCTAssertEqual(object.keyRotation?.cipher,nextCipher)
        XCTAssertEqual(object.keyRotation?.sent,true); try owner.validate()
        XCTAssertEqual(try JSONDecoder().decode(OwnerAccount.self,from:JSONEncoder().encode(owner)),owner)
    }
    private let master = Data(repeating: 7, count: 32)
    private func document(_ values: [String: String], integers: [String: Int] = [:]) throws -> AndroidBackupDocument {
        var entries: [String: Any] = values.mapValues { ["t": "s", "v": $0] }
        for (key, value) in integers { entries[key] = ["t": "i", "v": value] }
        return try AndroidBackupDocument(JSONSerialization.data(withJSONObject: ["app": "entrixy", "ver": 1,
            "created": 1_800_000_000, "device": "Public fixture", "count": entries.count, "entries": entries]))
    }
    private func json(_ value: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
    func testPerServerAccessCodeAndAccountEmailStayScopedWithoutSignInSecrets() throws {
        let id = String(repeating:"a",count:32), secret = String(repeating:"b",count:64)
        let accounts: [[String:Any]] = [["host":"first.invalid","id":id,"secret":secret,"email":"one@example.test"],["host":"second.invalid","id":id,"secret":secret,"email":"two@example.test"]]
        let source = try document(["owner_accounts":json(accounts),"access_code_first.invalid":"first-code","access_code_second.invalid":"second-code"])
        let owners = try AndroidOwnerAdapter.owners(from:source)
        let first = try XCTUnwrap(owners.first { $0.server == "first.invalid" }), second = try XCTUnwrap(owners.first { $0.server == "second.invalid" })
        XCTAssertEqual(first.serverSettings?.accountEmail,"one@example.test"); XCTAssertEqual(first.serverSettings?.accessCode,"first-code")
        XCTAssertEqual(second.serverSettings?.accountEmail,"two@example.test"); XCTAssertEqual(second.serverSettings?.accessCode,"second-code")
        XCTAssertEqual(first.credentials?.deviceID,id); XCTAssertNil(first.serverSettings?.pendingAccount); XCTAssertNil(first.registrationPhase)
    }
    func testMultiServerAliasesObjectKeysSocketBLESecretsAndSignedRevokesSurviveTranslation() throws {
        let keyA = Data(repeating: 8, count: 32), keyB = Data(repeating: 9, count: 32)
        let bleSecret = Data(repeating: 10, count: 32), socket = Data(repeating: 11, count: 32)
        let cipherA = try GuestCrypto.encrypt(key: keyA, plaintext: Data(#"{"label":"Первый сервер","avatar_type":"preset:1"}"#.utf8))
        let cipherB = try GuestCrypto.encrypt(key: keyB, plaintext: Data(#"{"label":"Второй сервер","avatar_type":"preset:2"}"#.utf8))
        let record = try BLERevocation(deviceID: 0xf1234567, guestID: 9, version: 100, revoked: true, ownerSecret: bleSecret)
        let user = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX", guestKey = Data(repeating: 12, count: 32)
        let values: [String: String] = [
            "e2ee_master_key": GuestCrypto.base64URL(master), "backup_server_host": "first.invalid",
            "guest_templates": try json(["k0n7": ["auth_on": true, "auth": "pin"]]),
            "ble_templates": try json(["8": ["auth_on": true, "auth": "biometric"]]),
            "owner_accounts": try json(["first.invalid", "second.invalid"].map { ["host": $0, "id": String(repeating: "a", count: 32), "secret": String(repeating: "b", count: 64)] }),
            "obj_alias": try json(["7": "first.invalid|7", "1000000": "second.invalid|7", "8": "first.invalid|8"]),
            "host_numbers": try json([["id": 7, "host": "first.invalid", "type": "call", "phone": "+15550000001"],
                ["id": 1000000, "host": "second.invalid", "type": "device", "did": 99]] as [[String: Any]]),
            "ble_objects": try json([["id": 8, "label": "BLE-ворота", "did": Int64(Int32(bitPattern: 0xf1234567)), "secret": bleSecret.base64EncodedString()]]),
            "e2ee_obj_7": try GuestCrypto.encrypt(key: master, plaintext: keyA), "e2ee_obj_blob_7": cipherA,
            "e2ee_obj_1000000": try GuestCrypto.encrypt(key: master, plaintext: keyB), "e2ee_obj_blob_1000000": cipherB,
            "sock_secret_1000000": socket.base64EncodedString(), "local_phone_7": "+15550000001",
            "blerev_\(Int32(bitPattern: 0xf1234567))": try json(["9": ["v": 100, "r": 1, "s": record.signature.base64EncodedString()]]),
            "key_17@first.invalid": user, "e2ee_guest_17@first.invalid": try GuestCrypto.encrypt(key: master, plaintext: guestKey),
            "press_pub_17@first.invalid": GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: user).publicKey.rawRepresentation),
            "owner_guest_label_17@first.invalid": "Друг",
            "snap_url_7":"http://camera.invalid/image?ts={ts}","snap_auth_7":"bearer","snap_val_7":"private-camera-value","snap_when_7":"nearby"]
        let source = try document(values, integers: ["ble_guest_did_17@first.invalid": 9,"hangup_7":5,"snap_int_7":10])
        let owners = try AndroidOwnerAdapter.owners(from: source)
        XCTAssertEqual(owners.count, 2)
        let first = try XCTUnwrap(owners.first { $0.server == "first.invalid" }), second = try XCTUnwrap(owners.first { $0.server == "second.invalid" })
        XCTAssertEqual(first.masterKey, master); XCTAssertEqual(second.masterKey, master)
        let call = try XCTUnwrap(first.objects?.first { $0.kind == "call" }), ble = try XCTUnwrap(first.objects?.first { $0.kind == "ble" })
        XCTAssertEqual(try OwnerManualPolicy(call.localPolicy).authentication, "pin")
        XCTAssertEqual(try OwnerManualPolicy(ble.localPolicy).authentication, "biometric")
        XCTAssertEqual(call.numberID, 7); XCTAssertEqual(call.cipher, cipherA); XCTAssertEqual(call.localPhone, "+15550000001")
        XCTAssertEqual(call.localConfiguration?.hangupSeconds,5)
        XCTAssertEqual(call.localConfiguration?.camera.authValue,"private-camera-value")
        XCTAssertEqual(call.localConfiguration?.camera.intervalSec,10)
        XCTAssertEqual(call.localConfiguration?.camera.showWhen,"nearby")
        XCTAssertFalse(String(decoding:call.cipher.data(using:.utf8)!,as:UTF8.self).contains("private-camera-value"))
        XCTAssertEqual(second.objects?.first?.numberID, 7); XCTAssertEqual(second.objects?.first?.cipher, cipherB)
        XCTAssertNotEqual(call.id, second.objects?.first?.id)
        XCTAssertEqual(try GuestCrypto.decrypt(key: master, envelope: ble.wrappedBLESecret!), bleSecret)
        XCTAssertEqual(try GuestCrypto.decrypt(key: master, envelope: second.objects!.first!.wrappedSocketSecret!), socket)
        XCTAssertEqual(ble.bleDeviceID, 0xf1234567)
        for owner in owners {
            for object in owner.objects ?? [] {
                XCTAssertEqual(object.available, false)
                XCTAssertNil(object.pending)
            }
        }
        XCTAssertEqual(first.bleRevocations?.first?.frame, record.frame); XCTAssertNil(first.bleRevocations?.first?.controllerResult)
        XCTAssertEqual(first.androidKeys?.first?.userKey, user)
        XCTAssertEqual(try GuestCrypto.decrypt(key: master, envelope: first.androidKeys!.first!.wrappedBundleKey!), guestKey)
        XCTAssertEqual(first.androidKeys?.first?.guestID, 9)
        let again = try AndroidOwnerAdapter.owners(from: source)
        XCTAssertEqual(again.flatMap { $0.objects ?? [] }.map(\.id), owners.flatMap { $0.objects ?? [] }.map(\.id))
    }
    func testCorruptMasterOrObjectKeyNeverGetsAReplacementAndForeignAliasIsRefused() throws {
        let sourceKey = Data(repeating: 8, count: 32)
        let cipher = try GuestCrypto.encrypt(key: sourceKey, plaintext: Data(#"{"label":"Ворота"}"#.utf8))
        var values: [String: String] = ["e2ee_master_key": GuestCrypto.base64URL(master),
            "host_numbers": try json([["id": 7, "host": "first.invalid", "type": "device"]]),
            "e2ee_obj_7": try GuestCrypto.encrypt(key: Data(repeating: 6, count: 32), plaintext: sourceKey), "e2ee_obj_blob_7": cipher]
        XCTAssertThrowsError(try AndroidOwnerAdapter.owners(from: document(values)))
        values["e2ee_obj_7"] = nil
        XCTAssertThrowsError(try AndroidOwnerAdapter.owners(from: document(values)))
        values["e2ee_obj_7"] = try GuestCrypto.encrypt(key: master, plaintext: sourceKey)
        values["obj_alias"] = try json(["7": "second.invalid|7"])
        XCTAssertThrowsError(try AndroidOwnerAdapter.owners(from: document(values)))
    }
    func testGuestPresetsAndServerScopedCompanyPinsAreReadFromOriginalPreferences() throws {
        let first = Data(repeating:21,count:32), second = Data(repeating:22,count:32)
        let user = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"
        let values = ["e2ee_master_key":GuestCrypto.base64URL(master),"owner_self_label":"Хозяин",
            "default_obj_access":try json(["id":0,"native_only":1,"depth":2,"pool":7]),
            "owner_accounts":try json(["first.invalid","second.invalid"].map { ["host":$0,"id":String(repeating:"a",count:32),"secret":String(repeating:"b",count:64)] }),
            "known_orgs":try json(["first.invalid","second.invalid"].map { ["host":$0,"id":11,"name":"Компания","verified":true] as [String:Any] }),
            "org_known_pub_11@first.invalid":first.base64EncodedString(),"org_known_pub_11@second.invalid":second.base64EncodedString(),
            "key_17@first.invalid":user,"key_17@second.invalid":user,
            "org_pub_17@first.invalid":first.base64EncodedString(),"pending_org_code":"SERVER_SPECIFIC_CODE"]
        let source = try document(values,integers:["key_org_17@first.invalid":11,"key_org_17@second.invalid":11,"pending_org_id":11])
        XCTAssertEqual(try source.guestDefaults().ownerName,"Хозяин")
        XCTAssertEqual(try source.guestDefaults().access,try KeyObjectAccess(nativeOnly:true,depth:2,pool:7))
        let companies = try source.companies(); XCTAssertEqual(companies.count,2)
        XCTAssertEqual(companies[0].companyID,companies[1].companyID); XCTAssertNotEqual(companies[0].id,companies[1].id)
        XCTAssertTrue(companies.allSatisfy { !$0.proven && $0.pendingCode == nil })
        XCTAssertEqual(try source.ownerKeyMaterial(server:"first.invalid",masterKey:master).first?.companyPublicKey,first)
        XCTAssertEqual(try source.ownerKeyMaterial(server:"second.invalid",masterKey:master).first?.companyPublicKey,second)
        let owners = try AndroidOwnerAdapter.owners(from:source)
        XCTAssertTrue(owners.allSatisfy { $0.hostLabel == "Хозяин" })
    }
}
