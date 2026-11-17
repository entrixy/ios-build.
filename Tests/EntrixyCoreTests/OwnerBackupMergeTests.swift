import XCTest
@testable import EntrixyCore

final class OwnerBackupMergeTests: XCTestCase {
    private func source() throws -> OwnerAccount {
        var owner = try OwnerAccount(server: "owner.invalid")
        owner.credentials = try OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64))
        var first = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "call", phone: "+15550000001")
        first.numberID = 7; first.pending = nil; first.available = true
        var second = try OwnerObject(masterKey: owner.masterKey, label: "Калитка", kind: "call", phone: "+15550000002")
        second.numberID = 8; second.pending = nil; second.available = true
        owner.objects = [first, second]
        var key = try OwnerIssuedKey(owner: owner, label: "Друг", numberIDs: [7,8], welcome: "", nativeOnly: false, confirmation: true)
        key.keyID = 17; key.pending = nil; key.state = .active
        owner.issuedKeys = [key]
        return owner
    }
    func testExistingOwnerReceivesMissingObjectsAndKeysWithoutReplacingPrivateIdentity() throws {
        let backup = try source()
        var current = backup; current.objects = [backup.objects![0]]; current.issuedKeys = []
        let merged = try current.mergingBackup(backup)
        XCTAssertEqual(merged.masterKey, current.masterKey)
        XCTAssertEqual(merged.credentials, current.credentials)
        XCTAssertEqual(merged.objects?.count, 2); XCTAssertEqual(merged.issuedKeys?.count, 1)
        XCTAssertEqual(merged.objects?.first?.wrappedKey, current.objects?.first?.wrappedKey)
        XCTAssertEqual(merged.issuedKeys?.first?.wrappedSecrets, backup.issuedKeys?.first?.wrappedSecrets)
        XCTAssertEqual(try merged.mergingBackup(backup), merged)
    }
    func testBackupCannotRemoveExistingNetworkRestrictionsOrReplaceSentKeyMaterial() throws {
        var current = try source(), imported = current
        current.privacyNetworks = [try PrivacyNetwork(ssid:"Current home")]
        imported.privacyNetworks = [try PrivacyNetwork(ssid:"Imported home")]
        current.issuedKeys![0].pending = .keyEdit; current.issuedKeys![0].sent = true
        imported.issuedKeys = nil
        let issued = current.issuedKeys![0]
        let merged = try current.mergingBackup(imported)
        XCTAssertEqual(merged.privacyNetworks?.map(\.ssid),["Current home","Imported home"])
        XCTAssertEqual(merged.issuedKeys![0],issued)
        XCTAssertNotNil(merged.bundleRefreshQueue?[issued.id.uuidString])
        XCTAssertEqual(merged.masterKey,current.masterKey)
        XCTAssertEqual(merged.credentials,current.credentials)
    }
    func testLegacyEncryptedRestrictionsArePreservedWhenAnImportedEmptyListDoesNotKnowThem() throws {
        var current = try source(), key = current.issuedKeys![0]
        let secrets = try key.secrets(masterKey:current.masterKey)
        var bundle = try key.bundle(masterKey:current.masterKey)
        bundle["net_block"] = [["s":"Legacy home"]]
        key.bundleCipher = try GuestCrypto.encrypt(key:secrets.bundleKey,plaintext:JSONSerialization.data(withJSONObject:bundle))
        current.issuedKeys = [key]
        var imported = current; imported.privacyNetworks = []
        let merged = try current.mergingBackup(imported)
        XCTAssertEqual(merged.privacyNetworks?.map(\.ssid),["Legacy home"])
        XCTAssertEqual(merged.issuedKeys![0].bundleCipher,key.bundleCipher)
        XCTAssertEqual(merged.issuedKeys![0].wrappedSecrets,key.wrappedSecrets)
    }
    func testDifferentPrivateObjectKeyAndConflictingGuestScopeAreRefusedBeforeMigration() throws {
        let backup = try source()
        var different = backup
        let original = backup.objects![0], key = Data(repeating: 12, count: 32)
        different.objects![0] = try OwnerObject(importing: original.id, numberID: 7, kind: "call",
            cipher: GuestCrypto.encrypt(key: key, plaintext: Data(#"{"label":"Другой объект"}"#.utf8)),
            wrappedKey: GuestCrypto.encrypt(key: backup.masterKey, plaintext: key), masterKey: backup.masterKey, phone: "+15550000001")
        XCTAssertThrowsError(try backup.mergingBackup(different))
        var scope = backup
        scope.issuedKeys![0].numberIDs = [7]
        XCTAssertThrowsError(try backup.mergingBackup(scope))
        XCTAssertEqual(backup.objects?.count, 2)
    }
    func testUnknownSentMetadataAndPairingCannotBecomeUnsentAfterRestore() throws {
        var backup = try source(); backup.issuedKeys = nil; backup.objects = [backup.objects![0]]
        backup.objects![0].numberID = nil; backup.objects![0].pending = .create; backup.objects![0].sent = true
        let peer = BLECrypto.makePair()
        var pairing = try BLEPairingRecord(masterKey: backup.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "BLE")
        var current = backup
        current.objects![0].sent = false; current.blePairings = [pairing]
        try pairing.markSent(); backup.blePairings = [pairing]
        let merged = try current.mergingBackup(backup)
        XCTAssertEqual(merged.objects?.first?.sent, true)
        XCTAssertEqual(merged.blePairings?.first?.phase, .sent)
        var restored = merged.blePairings![0]
        XCTAssertThrowsError(try restored.markSent())
    }
    func testOlderPendingAllowCannotOverrideNewerPhysicalRevocation() throws {
        var backup = try source()
        let peer = BLECrypto.makePair()
        var pairing = try BLEPairingRecord(masterKey: backup.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "BLE")
        try pairing.markSent()
        let secret = try pairing.secret(masterKey: backup.masterKey), head = Data([123,0,0,0,1,0,0,0])
        try pairing.confirm(advertisement: head + BLECrypto.hmac(secret, head).prefix(8), masterKey: backup.masterKey)
        var object = try OwnerObject(pairing: pairing, masterKey: backup.masterKey)
        object.numberID = 9; object.pending = nil; object.available = true
        backup.objects!.append(object)
        let gid = UInt16(backup.issuedKeys![0].guestID), rootID = backup.issuedKeys![0].id
        backup.bleRevocations = [try BLERevocation(deviceID: 123, guestID: gid, version: 100, revoked: true, ownerSecret: secret)]
        backup.scheduleBLERestoration(keyID: rootID)
        var current = backup; current.bleRestorePending = []
        current.bleRevocations = [try BLERevocation(deviceID: 123, guestID: gid, version: 101, revoked: true, ownerSecret: secret)]
        XCTAssertThrowsError(try current.mergingBackup(backup))
        XCTAssertEqual(current.bleRevocations?.first?.version, 101)
    }
}
