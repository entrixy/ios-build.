import XCTest
@testable import EntrixyCore

final class AndroidBackupDocumentTests: XCTestCase {
    private func payload(_ entries: [String: Any], count: Int? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["app": "entrixy", "ver": 1, "created": 1_800_000_000, "device": "Public fixture", "count": count ?? entries.count, "entries": entries], options: .sortedKeys)
    }
    func testTypedEntriesKeepOriginalAndNeverSubstituteIdentityOrSecrets() throws {
        let master = Data(repeating: 7, count: 32), bundleKey = Data(repeating: 8, count: 32)
        let seed = String(repeating: "a", count: 64), user = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"
        let entries: [String: Any] = [
            "backup_src_seed": ["t": "s", "v": seed], "backup_server_host": ["t": "s", "v": "owner.invalid"],
            "e2ee_master_key": ["t": "s", "v": GuestCrypto.base64URL(master)],
            "owner_accounts": ["t": "s", "v": #"[{"host":"owner.invalid","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]"#],
            "guest_keys": ["t": "s", "v": "[{\"id\":3,\"key\":\"\(user)\",\"host\":\"other.invalid\"}]"],
            "e2ee_in_guest_3": ["t": "s", "v": try GuestCrypto.encrypt(key: master, plaintext: bundleKey)],
            "future_flag": ["t": "b", "v": true], "future_set": ["t": "ss", "v": ["a", "b"]],
            "long_value": ["t": "l", "v": Int64.max]]
        let bytes = try payload(entries), document = try AndroidBackupDocument(bytes)
        XCTAssertEqual(document.original, bytes)
        XCTAssertEqual(try document.sourceSeed(required: true), seed)
        XCTAssertEqual(try document.owners().first?.server, "owner.invalid")
        let guest = try XCTUnwrap(document.guests().first)
        XCTAssertEqual(try document.invitation(for: guest)?.bundleKey, bundleKey)
        XCTAssertEqual(try document.invitation(for: guest)?.server, "other.invalid")
        XCTAssertEqual(document.entries["long_value"], .long(Int64.max))
        let restored = try JSONDecoder().decode(AndroidBackupDocument.self, from: JSONEncoder().encode(document))
        try restored.validate()
        XCTAssertEqual(restored.entries["future_flag"], .boolean(true))
        XCTAssertEqual(restored.entries["future_set"], .strings(["a", "b"]))
    }
    func testRecipientPrivateKeyIsRecoveredFromOriginalWrappedAndroidEntry() throws {
        let master = Data(repeating: 7, count: 32), recipient = BundleKeySeal.makeRecipient()
        let group = String(repeating: "A", count: 22), user = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"
        let guestsJSON = String(data: try JSONSerialization.data(withJSONObject: [["id": 3, "key": user, "host": "owner.invalid"]]), encoding: .utf8)!
        var entries: [String: Any] = [
            "backup_src_seed": ["t": "s", "v": String(repeating: "a", count: 64)],
            "e2ee_master_key": ["t": "s", "v": GuestCrypto.base64URL(master)],
            "guest_keys": ["t": "s", "v": guestsJSON],
            "share_grp_3": ["t": "s", "v": group], "share_pub_\(group)": ["t": "s", "v": recipient.publicKey],
            "share_priv_\(group)": ["t": "s", "v": try GuestCrypto.encrypt(key: master, plaintext: Data(recipient.privateKey.utf8))]]
        let document = try AndroidBackupDocument(payload(entries)), guest = try XCTUnwrap(document.guests().first)
        XCTAssertNil(try document.invitation(for: guest))
        XCTAssertEqual(try document.recipient(for: guest)?.privateKey, recipient.privateKey)
        entries["share_pub_\(group)"] = ["t": "s", "v": BundleKeySeal.makeRecipient().publicKey]
        let wrong = try AndroidBackupDocument(payload(entries))
        XCTAssertThrowsError(try wrong.recipient(for: guest))
    }

    func testMalformedCountsTypesSecretsAndAliasesFailBeforeAnyMigration() throws {
        XCTAssertThrowsError(try AndroidBackupDocument(payload(["flag": ["t": "b", "v": 1]])))
        XCTAssertThrowsError(try AndroidBackupDocument(payload(["x": ["t": "s", "v": "v"]], count: 0)))
        XCTAssertThrowsError(try AndroidBackupDocument(payload(["x": ["t": "unknown", "v": "v"]])))
        XCTAssertThrowsError(try AndroidBackupDocument(payload(["e2ee_master_key": ["t": "s", "v": "bad"]])))
        let missing = try AndroidBackupDocument(payload(["guest_keys": ["t": "s", "v": "[]"]]))
        XCTAssertNil(try missing.masterKey())
        XCTAssertThrowsError(try missing.sourceSeed(required: true))
        let duplicateSet = ["x": ["t": "ss", "v": ["same", "same"]]] as [String: Any]
        XCTAssertThrowsError(try AndroidBackupDocument(payload(duplicateSet)))
        let aliases = try AndroidBackupDocument(payload(["obj_alias": ["t": "s", "v": #"{"1000000":"second.invalid|7"}"#]]))
        let ref = try aliases.objectReference(localID: 1000000)
        XCTAssertEqual(ref.server, "second.invalid"); XCTAssertEqual(ref.numberID, 7)
        XCTAssertThrowsError(try aliases.objectReference(localID: 1000000, fallbackServer: "first.invalid"))
    }
}
