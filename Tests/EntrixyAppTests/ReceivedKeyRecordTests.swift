import XCTest
import EntrixyCore
@testable import Entrixy

private final class ReceivedKeyState: StateStorage {
    var state: SavedState?
    var failSave = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { if failSave { throw KeychainStore.Failure(status:-1) }; self.state = state }
}
@MainActor final class ReceivedKeyRecordTests: XCTestCase {
    private func guest(_ byte: UInt8, group: String? = nil, name: String) throws -> SavedGuest {
        let key = GuestCrypto.base64URL(Data(repeating:byte,count:24)), bundle = GuestCrypto.base64URL(Data(repeating:byte+1,count:32))
        let invite = try GuestInvite.parse("https://keys.invalid/key#" + key + bundle)
        var guest = SavedGuest(invite:invite)
        guest.objects = try JSONDecoder().decode([GuestObject].self,from:JSONSerialization.data(withJSONObject:[["id":"n:7","numberID":7,"kind":"device","label":name]]))
        guest.keyGroup = group; guest.senderLabel = group == nil ? nil : "Анна"; guest.hostLabel = "Владелец"
        return guest
    }
    func testGroupedKeyHasOneRowAndRemovalClearsAllPartsWithoutTouchingOtherKey() throws {
        let group = "keys.invalid:" + String(repeating:"G",count:22)
        let first = try guest(11,group:group,name:"Ворота"), second = try guest(21,group:group,name:"Дверь"), other = try guest(31,name:"Другой объект")
        let store = ReceivedKeyState(); store.state = SavedState(identity:Data(repeating:71,count:32),guests:[first,second,other])
        let app = AppModel(storage:store); defer { app.suspend() }
        XCTAssertEqual(app.receivedKeyRecords.count,2)
        let row = try XCTUnwrap(app.receivedKeyRecords.first)
        XCTAssertEqual(row.title,"Анна"); XCTAssertEqual(row.objectNames,"Ворота, Дверь")
        app.removeReceivedKeyRecord(row.id)
        XCTAssertEqual(app.guests.map(\.id),[other.id]); XCTAssertEqual(store.state?.guests.map(\.id),[other.id])
        XCTAssertEqual(store.state?.identity,Data(repeating:71,count:32)); XCTAssertTrue(app.journal.isEmpty)
    }
    func testGroupDeletionWriteFailureKeepsEveryPartAndDisplayOverride() throws {
        let group = "keys.invalid:" + String(repeating:"G",count:22)
        var first = try guest(11,group:group,name:"Ворота"); first.localKeyLabel = "Мой вход"
        let second = try guest(21,group:group,name:"Дверь")
        let store = ReceivedKeyState(); store.state = SavedState(identity:Data(repeating:71,count:32),guests:[first,second])
        let app = AppModel(storage:store); defer { app.suspend() }; store.failSave = true
        app.removeReceivedKeyRecord(group)
        XCTAssertEqual(app.guests.count,2); XCTAssertEqual(app.receivedKeyRecords.first?.title,"Мой вход")
        XCTAssertEqual(store.state?.guests.count,2); XCTAssertNotNil(app.errorMessage)
    }
    func testMigratedRecipientStillOpensDelegatedMessageWithoutANativeReceipt() throws {
        var source = try guest(11,name:"Ворота")
        let recipient = BundleKeySeal.makeRecipient(); source.incomingRecipient = recipient; source.senderLabel = "Анна"
        let store = ReceivedKeyState(); store.state = SavedState(identity:Data(repeating:71,count:32),guests:[source])
        let app = AppModel(storage:store); defer { app.suspend() }
        let cipher = try GuestMessageCrypto.seal("Закройте после входа",recipientPublic:recipient.publicKey)
        let message = SavedMessage(guestID:source.id,cipher:cipher,receivedAt:Date())
        let manager = MessageManager(app:app)
        XCTAssertEqual(try manager.text(message),"Закройте после входа"); XCTAssertEqual(manager.sender(message),"Анна")
    }
}
