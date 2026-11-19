import XCTest
@testable import EntrixyCore

final class OwnerObjectKeyRotationTests: XCTestCase {
    private func owner() throws -> OwnerAccount {
        var owner = try OwnerAccount(server: "owner.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "call", phone: "+15550000001")
        object.numberID = 7; object.revision = 100; object.pending = nil; object.available = true
        owner.objects = [object]
        return owner
    }
    private func issued(_ owner: OwnerAccount, id: Int = 17) throws -> OwnerIssuedKey {
        var key = try OwnerIssuedKey(owner: owner, label: "Гость", numberIDs: [7], welcome: "Добро пожаловать", nativeOnly: false, confirmation: true)
        key.keyID = id; key.pending = nil; key.sent = false; key.state = .active; key.effectiveNumberIDs = [7]
        return key
    }
    private func snapshot(_ owner: OwnerAccount, extra: [[String: Any]] = [], cipher: String? = nil) throws -> OwnerSnapshot {
        let keys: [[String: Any]] = (owner.issuedKeys ?? []).map {
            ["id": $0.keyID!, "enabled": $0.state == .revoked ? 0 : 1, "mode": $0.state == .paused ? "off" : "auto",
             "number_ids": $0.effectiveNumberIDs ?? $0.numberIDs, "bundle_cipher": $0.bundleCipher]
        }
        return try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [["id":7,"type":"call",
            "data_cipher":cipher ?? owner.objects![0].cipher,"data_cipher_revision":101]], "keys": keys + extra]))
    }
    private func prepare(_ account: inout OwnerAccount) throws {
        account.objects![0].keyRotationQueued = true
        try account.prepareObjectKeyRotations()
    }

    func testPreparedRotationKeepsReadableMetadataAvatarAndExactCheckpointAcrossRestart() throws {
        var account = try owner()
        try account.objects![0].updateAvatar(preset: nil, jpeg: Data([1,2,3]), masterKey: account.masterKey)
        account.objects![0].pending = nil; account.objects![0].sent = false
        account.objects![0].pendingHasAvatar = nil; account.objects![0].editBaseline = nil
        let before = account.objects![0]
        try prepare(&account)
        let object = account.objects![0], rotation = try XCTUnwrap(object.keyRotation)
        XCTAssertEqual(object.cipher, before.cipher); XCTAssertEqual(object.wrappedKey, before.wrappedKey)
        XCTAssertEqual(try object.metadata(masterKey: account.masterKey)["label"] as? String, "Ворота")
        XCTAssertEqual(try object.avatar(masterKey: account.masterKey), Data([1,2,3]))
        let old = try GuestCrypto.decrypt(key: account.masterKey, envelope: object.wrappedKey)
        XCTAssertThrowsError(try GuestCrypto.decrypt(key: old, envelope: rotation.cipher))
        let restarted = try JSONDecoder().decode(OwnerAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(restarted, account); try restarted.validate()
        try account.prepareObjectKeyRotations()
        XCTAssertEqual(account.objects![0].keyRotation, rotation)
    }

    func testEveryRemainingRecipientIncludingPausedMustConfirmBothKeysBeforePublication() throws {
        var account = try owner(); var key = try issued(account)
        key.state = .paused; account.issuedKeys = [key]
        try prepare(&account)
        let id = account.objects![0].id, identity = key.wrappedSecrets
        XCTAssertFalse(try account.canPublishKeyRotation(objectID: id, snapshot: snapshot(account)))
        try key.refreshObjectSettings(owner: account)
        let bundle = try key.bundle(masterKey: account.masterKey)
        XCTAssertEqual(key.wrappedSecrets, identity); XCTAssertEqual(key.guestID, account.issuedKeys![0].guestID)
        XCTAssertEqual(bundle["welcome"] as? String, "Добро пожаловать")
        XCTAssertEqual((bundle["obj_epoch"] as? [String:Int])?["7"], 2)
        account.issuedKeys = [key]
        XCTAssertFalse(try account.canPublishKeyRotation(objectID: id, snapshot: snapshot(account)))
        key.pending = nil; account.issuedKeys = [key]
        XCTAssertTrue(try account.canPublishKeyRotation(objectID: id, snapshot: snapshot(account)))
        XCTAssertFalse(try account.canPublishKeyRotation(objectID: id, snapshot: snapshot(account,
            extra: [["id":99,"enabled":1,"number_ids":[7],"bundle_cipher":"unknown Android slot"]])))
        XCTAssertFalse(try account.canPublishKeyRotation(objectID: id, snapshot: snapshot(account,
            extra: [["id":99,"enabled":1,"number_ids":"invalid"]])))
        key.pending = .keyCreate; key.keyID = nil; account.issuedKeys = [key]
        XCTAssertFalse(try account.canPublishKeyRotation(objectID: id, snapshot: snapshot(owner())))
    }

    func testLostReplyCommitsOnlyExactCipherAndFurtherRevocationKeepsOnlyOnePreviousGeneration() throws {
        var account = try owner(); try prepare(&account)
        let old = account.objects![0].wrappedKey, prepared = account.objects![0].keyRotation!
        account.objects![0].keyRotation?.sent = true
        try account.reconcileObjects(snapshot(account))
        XCTAssertEqual(account.objects![0].keyRotation?.cipher, prepared.cipher)
        account.objects![0].keyRotationQueued = true // Another revoked recipient had already received generation2.
        try account.reconcileObjects(snapshot(account, cipher: prepared.cipher))
        XCTAssertNil(account.objects![0].keyRotation)
        XCTAssertEqual(account.objects![0].previousWrappedKey, old); XCTAssertEqual(account.objects![0].keyEpoch, 2)
        try account.prepareObjectKeyRotations()
        let second = account.objects![0].keyRotation!
        account.objects![0].keyRotation?.sent = true
        try account.reconcileObjects(snapshot(account, cipher: second.cipher))
        XCTAssertEqual(account.objects![0].keyEpoch, 3)
        XCTAssertEqual(account.objects![0].previousWrappedKey, prepared.wrappedKey)
        XCTAssertNotEqual(account.objects![0].previousWrappedKey, old)
        try account.validate()
    }

    func testPauseDoesNotRotateButConfirmedRevocationAndScopeRemovalDo() throws {
        var previous = try owner(); previous.issuedKeys = [try issued(previous)]
        var paused = previous; paused.issuedKeys![0].state = .paused
        paused.queueObjectKeyRotations(after: previous)
        XCTAssertFalse(paused.hasObjectKeyRotations)
        var revoked = previous; revoked.issuedKeys![0].state = .revoked
        revoked.queueObjectKeyRotations(after: previous)
        XCTAssertTrue(revoked.hasObjectKeyRotations)
        revoked.objects![0].keyRotationQueued = false
        let accepted = revoked
        revoked.queueObjectKeyRotations(after: accepted)
        XCTAssertFalse(revoked.hasObjectKeyRotations)
        var narrowed = previous; narrowed.issuedKeys![0].effectiveNumberIDs = []
        narrowed.queueObjectKeyRotations(after: previous)
        XCTAssertTrue(narrowed.hasObjectKeyRotations)
    }

    func testConcurrentObjectEditsWaitAndOldBackupCannotDiscardOrReplaceRotation() throws {
        var account = try owner(); let oldBackup = account
        try prepare(&account)
        XCTAssertThrowsError(try account.objects![0].rename("Новая запись", masterKey: account.masterKey))
        XCTAssertThrowsError(try account.objects![0].updateAvatar(preset: 1, jpeg: nil, masterKey: account.masterKey))
        XCTAssertEqual(try account.mergingBackup(oldBackup).objects, account.objects)
        XCTAssertThrowsError(try oldBackup.mergingBackup(account))
        account.objects![0].keyRotation?.sent = true
        let cipher = account.objects![0].keyRotation!.cipher
        try account.reconcileObjects(snapshot(account, cipher: cipher))
        XCTAssertThrowsError(try account.mergingBackup(oldBackup))
    }

    func testPublicationHoldsOnConcurrentMetadataChangeRatherThanOverwritingIt() throws {
        var account = try owner(); try prepare(&account)
        let key = try GuestCrypto.decrypt(key: account.masterKey, envelope: account.objects![0].wrappedKey)
        let other = try GuestCrypto.encrypt(key: key, plaintext: Data(#"{"label":"Изменено на сервере"}"#.utf8))
        try account.reconcileObjects(snapshot(account, cipher: other))
        XCTAssertFalse(try account.canPublishKeyRotation(objectID: account.objects![0].id, snapshot: snapshot(account)))
        XCTAssertEqual(try account.objects![0].metadata(masterKey: account.masterKey)["label"] as? String, "Изменено на сервере")
    }
}
