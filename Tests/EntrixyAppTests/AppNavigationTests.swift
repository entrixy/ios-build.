import XCTest
import EntrixyCore
@testable import Entrixy

final class AppNavigationTests: XCTestCase {
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
