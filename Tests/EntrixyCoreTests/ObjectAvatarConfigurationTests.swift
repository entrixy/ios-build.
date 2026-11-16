import XCTest
@testable import EntrixyCore

final class ObjectAvatarConfigurationTests: XCTestCase {
    private let master = Data(repeating: 86, count: 32)
    private func object() throws -> OwnerObject {
        var object = try OwnerObject(masterKey: master, label: "Ворота", kind: "call", phone: "+15550000001")
        object.numberID = 7; object.pending = nil; object.available = true; object.revision = 5
        return object
    }
    func testCustomAvatarIsEncryptedAndUnsentChangeRestoresPreviousImage() throws {
        var object = try object(); let previous = object
        let bytes = Data("synthetic-image-bytes".utf8)
        try object.updateAvatar(preset: nil, jpeg: bytes, masterKey: master)
        XCTAssertEqual(try object.avatar(masterKey: master), bytes)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: object.request()) as? [String: Any])
        XCTAssertEqual(request["has_avatar"] as? Bool, true)
        XCTAssertNil(request["avatar_cipher"])
        XCTAssertEqual(object.wrappedKey, previous.wrappedKey)
        var restarted = try JSONDecoder().decode(OwnerObject.self, from: JSONEncoder().encode(object))
        try restarted.validate(masterKey: master)
        try restarted.cancelConfigurationUpdate(); XCTAssertEqual(restarted, previous)
    }
    func testPresetClearsOldFileAndRejectsAmbiguousMutation() throws {
        var object = try object()
        try object.updateAvatar(preset: nil, jpeg: Data([1,2,3]), masterKey: master)
        object.pending = nil; object.editBaseline = nil; object.pendingHasAvatar = nil
        try object.updateAvatar(preset: 6, jpeg: nil, masterKey: master)
        XCTAssertNil(try object.avatar(masterKey: master))
        XCTAssertEqual(try object.metadata(masterKey: master)["avatar_type"] as? String, "preset:6")
        object.sent = true; let previous = object
        XCTAssertThrowsError(try object.updateAvatar(preset: 2, jpeg: nil, masterKey: master))
        XCTAssertThrowsError(try object.cancelConfigurationUpdate()); XCTAssertEqual(object, previous)
    }
    func testReceivedOverrideIsPrivateAndScopedToItsKey() throws {
        let first = ObjectReference.received(guestID: "a", objectID: "n:7")
        let second = ObjectReference.received(guestID: "b", objectID: "n:7")
        var preferences = ObjectCatalogPreferences()
        try preferences.setAvatar(first, preset: nil, jpeg: Data([1,2,3]), localKey: master)
        XCTAssertEqual(try preferences.avatar(first, localKey: master), Data([1,2,3]))
        XCTAssertNil(try preferences.avatar(second, localKey: master))
        XCTAssertThrowsError(try preferences.avatar(first, localKey: Data(repeating: 1,count:32)))
        try preferences.setAvatar(first, preset: 4, jpeg: nil, localKey: master)
        XCTAssertNil(try preferences.avatar(first, localKey: master))
        XCTAssertEqual(preferences.presentation(for: first).avatarPreset, 4)
    }
}
