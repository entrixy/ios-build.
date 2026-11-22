import XCTest
@testable import EntrixyCore

final class AndroidGuestMigrationTests: XCTestCase {
    private func document(bundle: Bool, grouped: Bool = false) throws -> AndroidBackupDocument {
        let master = Data(repeating:7,count:32)
        let recipient = BundleKeySeal.makeRecipient()
        var fields: [String:String] = ["backup_src_seed":String(repeating:"ab",count:32),
            "e2ee_master_key":GuestCrypto.base64URL(master),
            "guest_keys":#"[{"id":3,"host":"owner.invalid","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX","label":"Ключ"}]"#,
            "dlg_pub_3":recipient.publicKey,"dlg_priv_3":try GuestCrypto.encrypt(key:master,plaintext:Data(recipient.privateKey.utf8)),"unknown_future_setting":"retain-exactly"]
        if bundle { fields["e2ee_in_guest_3"] = try GuestCrypto.encrypt(key:master,plaintext:Data(repeating:12,count:32)) }
        if grouped {
            let group = String(repeating:"G",count:22)
            fields["share_grp_3"] = group; fields["share_from_" + group] = "Анна"
            fields["share_wk_" + group] = GuestCrypto.base64URL(Data(repeating:42,count:32))
            fields["share_pub_" + group] = recipient.publicKey
            fields["share_priv_" + group] = fields["dlg_priv_3"]
            fields["guest_key_labels"] = #"{"3":"Двор"}"#
        }
        let entries = fields.mapValues { ["t":"s","v":$0] }
        return try AndroidBackupDocument(JSONSerialization.data(withJSONObject:["app":"entrixy","ver":1,"created":1800000000,"device":"Public fixture","count":entries.count,"entries":entries]))
    }
    func testRealSigningAndRecipientIdentitySurvivesBeforeOwnerProvidesBundle() throws {
        let original = try document(bundle:false), source = try XCTUnwrap(original.guestMigrations().first)
        XCTAssertNil(source.bundleKey); XCTAssertNotNil(source.recipient)
        XCTAssertEqual(source.identity.userKey,"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX")
        XCTAssertEqual(source.oldFingerprint,try MigrationFingerprint.android(seed:String(repeating:"ab",count:32),server:"owner.invalid"))
        let decoded = try JSONDecoder().decode(AndroidGuestMigration.self,from:JSONEncoder().encode(source))
        XCTAssertEqual(decoded.identity,source.identity); XCTAssertEqual(decoded.recipient?.privateKey,source.recipient?.privateKey)
        XCTAssertEqual(decoded.oldFingerprint,source.oldFingerprint)
        XCTAssertEqual(try JSONDecoder().decode(AndroidBackupDocument.self,from:JSONEncoder().encode(original)).original,original.original)
        XCTAssertEqual(try original.string("unknown_future_setting"),"retain-exactly")
    }
    func testExistingGuestBundleIsUnwrappedWithoutGeneratingReplacementMaterial() throws {
        let source = try XCTUnwrap(document(bundle:true).guestMigrations().first)
        XCTAssertEqual(source.bundleKey,Data(repeating:12,count:32))
        let invite = try source.identity.invitation(bundleKey:XCTUnwrap(source.bundleKey))
        XCTAssertEqual(invite.userKey,source.identity.userKey)
        let original = try document(bundle:true)
        XCTAssertThrowsError(try AndroidBackupDocument.validateArchives([original,original]))
        XCTAssertNoThrow(try AndroidBackupDocument.validateArchives([original]))
    }
    func testGroupSecretSenderAndOverrideSurviveMigrationWithOriginalRecipient() throws {
        let original = try document(bundle:true,grouped:true)
        let source = try XCTUnwrap(original.guestMigrations().first)
        XCTAssertEqual(source.groupID,"owner.invalid:" + String(repeating:"G",count:22))
        XCTAssertEqual(source.delegationLink?.secret,Data(repeating:42,count:32))
        XCTAssertEqual(source.senderLabel,"Анна"); XCTAssertEqual(source.labelOverride,"Двор")
        XCTAssertEqual(source.recipient?.publicKey,try original.string("share_pub_" + String(repeating:"G",count:22)))
        let saved = try JSONDecoder().decode(AndroidGuestMigration.self,from:JSONEncoder().encode(source))
        XCTAssertEqual(saved.delegationLink,source.delegationLink)
        XCTAssertEqual(saved.recipient?.privateKey,source.recipient?.privateKey)
    }
}
