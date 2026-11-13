import XCTest
import Security
import UIKit
import EntrixyCore
@testable import Entrixy

final class AppStateTests: XCTestCase {
    private let service = "com.entrixy.ios.tests." + UUID().uuidString
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "primary"]
    }
    override func tearDown() { SecItemDelete(query as CFDictionary); super.tearDown() }

    private var inviteText: String {
        "https://example.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43)
    }

    @MainActor func testRemovingKeyAndClearingJournalPreserveIdentityAcrossLaunches() throws {
        let store = KeychainStore(service: service)
        let identity = Data(repeating: 37, count: 32)
        let guest = SavedGuest(invite: try GuestInvite.parse(inviteText))
        let action = JournalEntry(who: "Я", what: "Тестовая калитка", actionKey: "test-action", result: "Opened", level: "success")
        try store.save(SavedState(identity: identity, guests: [guest], journal: [action]))
        let first = AppModel(storage: store)
        XCTAssertTrue(first.storageReady)
        first.removeKey(guest.id)
        XCTAssertTrue(first.guests.isEmpty)
        XCTAssertEqual(first.journal.count, 1)
        let second = AppModel(storage: store)
        XCTAssertEqual(second.journal.count, 1)
        XCTAssertEqual(try store.load()?.identity, identity)
        second.clearJournal()
        XCTAssertTrue(AppModel(storage: store).journal.isEmpty)
        XCTAssertEqual(try store.load()?.identity, identity)
    }

    @MainActor func testCorruptKeychainNeverCreatesReplacementIdentity() throws {
        let original = Data("not decodable state".utf8)
        var insert = query
        insert[kSecValueData as String] = original
        XCTAssertEqual(SecItemAdd(insert as CFDictionary, nil), errSecSuccess)
        let model = AppModel(storage: KeychainStore(service: service))
        XCTAssertFalse(model.storageReady)
        XCTAssertNotNil(model.errorMessage)
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, original)
    }

    @MainActor func testLegacyStateLoadsWithoutJournalAndReusesIdentity() throws {
        let identity = Data(repeating: 51, count: 32)
        let legacy = try JSONSerialization.data(withJSONObject: ["identity": identity.base64EncodedString(), "guests": []])
        var insert = query
        insert[kSecValueData as String] = legacy
        XCTAssertEqual(SecItemAdd(insert as CFDictionary, nil), errSecSuccess)
        let store = KeychainStore(service: service)
        let model = AppModel(storage: store)
        XCTAssertTrue(model.storageReady)
        XCTAssertTrue(model.journal.isEmpty)
        XCTAssertEqual(try store.load()?.identity, identity)
    }

    @MainActor func testLegacyDiagnosticsAreNotActionHistory() throws {
        let identity = Data(repeating: 52, count: 32)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "identity": identity.base64EncodedString(), "guests": [],
            "journal": [["id": UUID().uuidString, "date": 12345, "message": "Данные обновлены", "isError": false]]
        ])
        var insert = query
        insert[kSecValueData as String] = legacy
        XCTAssertEqual(SecItemAdd(insert as CFDictionary, nil), errSecSuccess)
        let store = KeychainStore(service: service)
        let model = AppModel(storage: store)
        XCTAssertTrue(model.storageReady)
        XCTAssertTrue(model.journal.isEmpty)
        XCTAssertEqual(try store.load()?.identity, identity)
        model.recordAction(JournalEntry(who: "Я", what: "Калитка", actionKey: "test"))
        model.actionResult(actionKey: "test", result: "Opened", level: "success")
        let restored = AppModel(storage: store)
        XCTAssertEqual(restored.journal.count, 1)
        XCTAssertEqual(restored.journal.first?.who, "Я")
        XCTAssertEqual(restored.journal.first?.what, "Калитка")
        XCTAssertEqual(restored.journal.first?.result, "Opened")
    }

    func testPhotoQRDecodesFullInviteAndRejectsImageWithoutQR() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "guest-invite-qr", withExtension: "png"))
        let bytes = try Data(contentsOf: url)
        let decoded = try await QRPhotoReader.read(bytes)
        XCTAssertEqual(decoded, inviteText)
        let blankURL = try XCTUnwrap(bundle.url(forResource: "no-qr", withExtension: "png"))
        let blankBytes = try Data(contentsOf: blankURL)
        do { _ = try await QRPhotoReader.read(blankBytes); XCTFail("Blank image must not import a key") }
        catch {}
    }
}
