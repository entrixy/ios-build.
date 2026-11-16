import XCTest
@testable import EntrixyCore

final class ObjectCatalogTests: XCTestCase {
    func testIdentitySeparatesServersKeysAndKindsWithoutExposingTheGuestKey() throws {
        let uuid = UUID()
        let targets: [ObjectReference] = [.owned(server: "a.invalid", objectID: uuid), .owned(server: "b.invalid", objectID: uuid),
            .received(guestID: "guest-a", objectID: "n:7"), .received(guestID: "guest-b", objectID: "n:7"),
            .received(guestID: "guest-a", objectID: "b:7")]
        XCTAssertEqual(Set(targets).count, 5)
        XCTAssertEqual(Set(targets.map(\.id)).count, 5)
        XCTAssertFalse(targets[2].id.contains("guest-a"))
        XCTAssertEqual(try JSONDecoder().decode([ObjectReference].self, from: JSONEncoder().encode(targets)), targets)
        for target in targets { try target.validate() }
    }
    func testOneOrderInterleavesOwnedIncomingAndBLEAndAppendsNewObjectsStably() {
        let a = ObjectReference.owned(server: "a.invalid", objectID: UUID())
        let b = ObjectReference.received(guestID: "g", objectID: "b:1")
        let c = ObjectReference.received(guestID: "g", objectID: "n:2")
        let new = ObjectReference.owned(server: "b.invalid", objectID: UUID())
        let prefs = ObjectCatalogPreferences(order: [c, a, b])
        XCTAssertEqual(prefs.sorted([a, new, b, c], reference: { $0 }), [c, a, b, new])
    }
    func testHideRenameReimportAndKeyRemovalHaveDifferentScope() throws {
        let a = ObjectReference.received(guestID: "g", objectID: "n:1")
        let b = ObjectReference.received(guestID: "g", objectID: "b:2")
        let other = ObjectReference.received(guestID: "other", objectID: "n:1")
        var prefs = ObjectCatalogPreferences(order: [a, other, b])
        try prefs.rename(a, label: "  Двор  "); try prefs.hide(a); try prefs.hide(other)
        XCTAssertTrue(prefs.presentation(for: a).hidden)
        XCTAssertNil(prefs.presentation(for: a).label)
        XCTAssertFalse(prefs.presentation(for: b).hidden)
        prefs.reveal([a, b])
        XCTAssertFalse(prefs.presentation(for: a).hidden)
        XCTAssertNil(prefs.presentation(for: a).label)
        XCTAssertTrue(prefs.presentation(for: other).hidden)
        prefs.removeGuest("g")
        XCTAssertEqual(prefs.order, [other])
        XCTAssertEqual(prefs.received.count, 1)
        try prefs.validate()
    }
    func testMalformedPreferencesAndOwnerRenameAreRejected() throws {
        let target = ObjectReference.owned(server: "a.invalid", objectID: UUID())
        XCTAssertThrowsError(try ObjectCatalogPreferences(order: [target, target]).validate())
        XCTAssertThrowsError(try ObjectReference.owned(server: "https://a.invalid/path", objectID: UUID()).validate())
        var prefs = ObjectCatalogPreferences()
        XCTAssertThrowsError(try prefs.rename(target, label: "Own metadata must use its encrypted update path"))
        XCTAssertThrowsError(try prefs.hide(target))
        XCTAssertThrowsError(try ObjectCatalogPreferences(received: ["unscoped": .init(label: "bad")]).validate())
    }
    func testBackupMergeKeepsCurrentDeviceChoicesAndRestoresOtherObjects() throws {
        let a = ObjectReference.received(guestID: "a", objectID: "n:1")
        let b = ObjectReference.received(guestID: "b", objectID: "n:1")
        var current = ObjectCatalogPreferences(order: [a]); try current.rename(a, label: "Current")
        var imported = ObjectCatalogPreferences(order: [b, a]); try imported.rename(a, label: "Old"); try imported.hide(b)
        let merged = try current.merging(imported)
        XCTAssertEqual(merged.order, [a, b])
        XCTAssertEqual(merged.presentation(for: a).label, "Current")
        XCTAssertTrue(merged.presentation(for: b).hidden)
        XCTAssertEqual(try current.merging(nil), current)
    }
}
