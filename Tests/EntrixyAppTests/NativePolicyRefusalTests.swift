import XCTest
import EntrixyCore
@testable import Entrixy

private final class NativeProofStorage: StateStorage {
    var state:SavedState
    var writes = 0
    init(_ state:SavedState) { self.state = state }
    func load() throws -> SavedState? { state }
    func save(_ state:SavedState) throws { self.state = state; writes += 1 }
}

@MainActor final class NativePolicyRefusalTests: XCTestCase {
    func testMissingPlatformProofStopsOnlineSessionWithoutRevokingOrReplacingInstalledKeys() throws {
        let invite = try GuestInvite.parse("https://guest.invalid/key#" + String(repeating:"A",count:32) + GuestCrypto.base64URL(Data(repeating:9,count:32)))
        let object = try JSONDecoder().decode(GuestObject.self,from:Data(#"{"id":"7","numberID":7,"kind":"device","label":"Fixture"}"#.utf8))
        let original = SavedState(identity:Data(repeating:7,count:32),guests:[SavedGuest(invite:invite,objects:[object])])
        let store = NativeProofStorage(original), app = AppModel(storage:store); defer { app.suspend() }
        let before = try JSONEncoder().encode(store.state)
        XCTAssertFalse(app.stopForNativePolicyRefusal(guestID:invite.id,reason:"server_error"))
        XCTAssertFalse(app.stopForNativePolicyRefusal(guestID:"missing",reason:"native_only"))
        XCTAssertTrue(app.stopForNativePolicyRefusal(guestID:invite.id,reason:"native_only"))
        XCTAssertNotNil(app.guestConnectionProblems[invite.id])
        XCTAssertEqual(app.connection(for:invite.id),.offline)
        XCTAssertFalse(app.guests[0].paused); XCTAssertEqual(app.guests[0].objects.count,1)
        XCTAssertNil(app.actionPrompt); XCTAssertTrue(app.journal.isEmpty); XCTAssertEqual(store.writes,0)
        // Compare semantic JSON rather than encoder dictionary order.
        XCTAssertEqual(try JSONSerialization.jsonObject(with:before) as? NSDictionary,
                       try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.state)) as? NSDictionary)
    }
}
