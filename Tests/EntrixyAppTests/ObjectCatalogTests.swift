import XCTest
import EntrixyCore
@testable import Entrixy

private final class CatalogStorage: StateStorage {
    var state: SavedState
    var failSave = false
    init(_ state: SavedState) { self.state = state }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if failSave { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}

final class ObjectCatalogModelTests: XCTestCase {
    private func fixture() throws -> SavedState {
        var owner = try OwnerAccount(importing: "owner.invalid", masterKey: Data(repeating: 12, count: 32),
            credentials: OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64)))
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Свои ворота", kind: "call", phone: "+70000000000")
        object.numberID = 7; object.pending = nil; object.available = true; object.revision = 1
        owner.objects = [object]
        let invite = try GuestInvite.parse("https://guest.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
        let objects = try JSONDecoder().decode([GuestObject].self, from: Data(#"[{"id":"n:7","numberID":7,"kind":"device","label":"Гостевые ворота"},{"id":"b:8","numberID":8,"kind":"ble","label":"Замок"}]"#.utf8))
        return SavedState(identity: Data(repeating: 28, count: 32), guests: [SavedGuest(invite: invite, objects: objects)], owners: [owner])
    }
    @MainActor func testMixedOrderAndLocalNameSurviveRelaunchAndOwnerSave() throws {
        let storage = CatalogStorage(try fixture())
        let model = AppModel(storage: storage)
        let targets = model.catalogObjects().map(\.target)
        model.reorderObjects([targets[2], targets[0], targets[1]])
        XCTAssertEqual(model.controlObjects.map(\.target), [targets[2], targets[0], targets[1]])
        XCTAssertTrue(model.renameReceivedObject(targets[1], label: "Новое имя"))
        let owner = model.owners[0], object = owner.objects![0]
        XCTAssertTrue(model.saveOwnerActionPolicy(server: owner.server, objectID: object.id, expected: nil, confirmation: true, authentication: "none"))
        let reloaded = AppModel(storage: storage)
        XCTAssertEqual(reloaded.controlObjects.map(\.target), model.controlObjects.map(\.target))
        XCTAssertEqual(reloaded.objectLabel(reloaded.catalogObject(targets[1])!), "Новое имя")
        XCTAssertEqual(reloaded.guests[0].objects[0].label, "Гостевые ворота")
        XCTAssertEqual(reloaded.guests[0].invite, model.guests[0].invite)
        XCTAssertTrue(reloaded.journal.isEmpty)
    }
    @MainActor func testHidingOneObjectKeepsKeySiblingAndMetadataAndBlocksStaleTap() throws {
        let model = AppModel(storage: CatalogStorage(try fixture()))
        let guest = model.guests[0], object = guest.objects[0]
        let target = ObjectReference.received(guestID: guest.id, objectID: object.id)
        XCTAssertTrue(model.hideReceivedObject(target))
        XCTAssertNil(model.catalogObject(target))
        XCTAssertEqual(model.guests[0].objects.count, 2)
        XCTAssertEqual(model.guests[0].invite, guest.invite)
        XCTAssertEqual(model.controlObjects.count, 2)
        XCTAssertNil(model.actionIntent(guestID: guest.id, object: object))
        XCTAssertTrue(model.journal.isEmpty)
    }
    @MainActor func testFailedWriteDoesNotPublishRenameHideOrOrder() throws {
        let storage = CatalogStorage(try fixture())
        let app = AppModel(storage: storage), previous = app.objectPreferences
        let targets = app.catalogObjects().map(\.target)
        storage.failSave = true
        XCTAssertFalse(app.renameReceivedObject(targets[1], label: "Lost"))
        XCTAssertFalse(app.hideReceivedObject(targets[1]))
        app.reorderObjects(Array(targets.reversed()))
        XCTAssertEqual(app.objectPreferences, previous)
        XCTAssertEqual(app.catalogObjects().map(\.target), targets)
        XCTAssertEqual(storage.state.objectPreferences, nil)
        XCTAssertEqual(storage.state.identity, Data(repeating: 28, count: 32))
    }
    @MainActor func testLegacyStateAndBackupKeepPresentationOptional() throws {
        let state = try fixture()
        let bytes = try JSONEncoder().encode(state)
        XCTAssertNil(try JSONDecoder().decode(SavedState.self, from: bytes).objectPreferences)
        let storage = CatalogStorage(state)
        let model = AppModel(storage: storage)
        let target = model.catalogObjects()[1].target
        XCTAssertTrue(model.renameReceivedObject(target, label: "Backup name"))
        let payload = IOSBackupPayload(state: storage.state)
        try payload.validate()
        XCTAssertEqual(payload.objectPreferences, model.objectPreferences)
    }
}
