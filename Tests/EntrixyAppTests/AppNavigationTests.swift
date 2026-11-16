import XCTest
import EntrixyCore
@testable import Entrixy

final class AppNavigationTests: XCTestCase {
    @MainActor func testOwnerDraftDoesNotSwitchToControlUntilTheCardIsAvailable() throws {
        var owner = try OwnerAccount(importing: "example.invalid", masterKey: Data(repeating: 22, count: 32),
            credentials: OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64)))
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "webhook", url: "https://example.invalid/open", secret: "fixture")
        owner.objects = [object]
        func model(_ owner: OwnerAccount) -> AppModel {
            var state = SavedState(identity: Data(repeating: 83, count: 32), guests: [])
            state.owners = [owner]
            return AppModel(storage: NavigationStateStorage(state: state))
        }
        XCTAssertEqual(model(owner).navigationState.tabs, [.settings, .guests, .journal])
        object.numberID = 7; object.pending = nil; object.available = true
        owner.objects = [object]
        XCTAssertEqual(model(owner).navigationState.tabs, [.control, .settings, .guests, .journal])
    }
    func testProfileTabsAndLossOfAvailability() {
        let empty = AppNavigationState(hasActions: false, hasOwnObjects: false, canDelegate: false)
        XCTAssertEqual(empty.tabs, [.settings, .journal])
        XCTAssertEqual(empty.resolve(.control), .settings)
        XCTAssertEqual(empty.resolve(.guests), .settings)
        XCTAssertEqual(empty.resolve(.journal), .journal)
        let guest = AppNavigationState(hasActions: true, hasOwnObjects: false, canDelegate: false)
        XCTAssertEqual(guest.tabs, [.control, .settings, .journal])
        let owner = AppNavigationState(hasActions: true, hasOwnObjects: true, canDelegate: false)
        XCTAssertEqual(owner.tabs, [.control, .settings, .guests, .journal])
        let delegating = AppNavigationState(hasActions: true, hasOwnObjects: false, canDelegate: true)
        XCTAssertEqual(delegating.tabs, owner.tabs)
        XCTAssertEqual(guest.resolve(delegating.resolve(.guests)), .settings)
    }
    func testLegacyGuestAndNavigationHintRoundTrip() throws {
        let invite = try GuestInvite.parse("https://example.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
        var guest = SavedGuest(invite: invite)
        let legacy = try JSONEncoder().encode(guest)
        XCTAssertNil(try JSONDecoder().decode(SavedGuest.self, from: legacy).incomingDepth)
        guest.incomingDepth = 2
        let restored = try JSONDecoder().decode(SavedGuest.self, from: JSONEncoder().encode(guest))
        XCTAssertEqual(restored.incomingDepth, 2)
        XCTAssertEqual(restored.invite, invite)
    }
}

private struct NavigationStateStorage: StateStorage {
    let state: SavedState
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {}
}
