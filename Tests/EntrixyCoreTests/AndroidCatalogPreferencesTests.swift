import XCTest
@testable import EntrixyCore

final class AndroidCatalogPreferencesTests: XCTestCase {
    private func document() throws -> AndroidBackupDocument {
        let users = [GuestCrypto.base64URL(Data(repeating:11,count:24)),GuestCrypto.base64URL(Data(repeating:12,count:24))]
        func json(_ value: Any) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self) }
        let strings: [String:String] = [
            "backup_src_seed":String(repeating:"ab",count:32),
            "guest_keys":try json([["id":3,"host":"first.invalid","key":users[0]],["id":4,"host":"second.invalid","key":users[1]]] as [[String:Any]]),
            "obj_alias":try json(["1000000":"second.invalid|7"]),
            "host_numbers":try json([["id":7,"host":"first.invalid","type":"call","phone":"+15550000001"],["id":1000000,"host":"second.invalid","type":"call","phone":"+15550000002"]] as [[String:Any]]),
            "all_action_order":"g4n7,h1000000,gb3b7,h7,g3n7,g3n7,g999n7",
            "overrides":try json(["g3n7":["label":"Вход со двора","avatar":"preset:2"],"g4n7":["label":"Другой сервер"],"gb3b7":["label":"Замок","avatar":"/data/user/0/app/private.jpg"]])]
        var entries: [String:Any] = strings.mapValues { ["t":"s","v":$0] }
        entries["hidden_objects"] = ["t":"ss","v":["3_b7","999_7"]]
        return try AndroidBackupDocument(JSONSerialization.data(withJSONObject:["app":"entrixy","ver":1,"created":1800000000,"device":"Public fixture","count":entries.count,"entries":entries]))
    }
    func testOrderNamesAndHiddenObjectsStayScopedByGuestAndOwnerServer() throws {
        let source = try document(), owners = try AndroidOwnerAdapter.owners(from:source)
        let guests = try source.guestMigrations(), first = try XCTUnwrap(guests.first { $0.localID == 3 }), second = try XCTUnwrap(guests.first { $0.localID == 4 })
        let preferences = try source.catalogPreferences(owners:owners)
        let number = ObjectReference.received(guestID:first.id,objectID:"n:7")
        let bluetooth = ObjectReference.received(guestID:first.id,objectID:"b:7")
        let other = ObjectReference.received(guestID:second.id,objectID:"n:7")
        let firstOwner = ObjectReference.owned(server:"first.invalid",objectID:AndroidOwnerAdapter.objectID(server:"first.invalid",numberID:7))
        let secondOwner = ObjectReference.owned(server:"second.invalid",objectID:AndroidOwnerAdapter.objectID(server:"second.invalid",numberID:7))
        XCTAssertEqual(preferences.order,[other,secondOwner,bluetooth,firstOwner,number])
        XCTAssertEqual(preferences.presentation(for:number).label,"Вход со двора")
        XCTAssertEqual(preferences.presentation(for:number).avatarPreset,2)
        XCTAssertEqual(preferences.presentation(for:other).label,"Другой сервер")
        XCTAssertTrue(preferences.presentation(for:bluetooth).hidden)
        XCTAssertNil(preferences.presentation(for:bluetooth).label)
        XCTAssertNil(preferences.presentation(for:bluetooth).avatarCipher)
        XCTAssertFalse(preferences.presentation(for:number).hidden)
        XCTAssertEqual(preferences.received.count,3)
    }
    func testCurrentPhoneChoicesWinWhenAndroidCatalogueIsMerged() throws {
        let source = try document(), incoming = try source.catalogPreferences(owners:AndroidOwnerAdapter.owners(from:source))
        let number = try XCTUnwrap(incoming.order.last)
        var current = ObjectCatalogPreferences(order:[number]); try current.rename(number,label:"На этом iPhone")
        let merged = try current.merging(incoming)
        XCTAssertEqual(merged.order.first,number); XCTAssertEqual(merged.presentation(for:number).label,"На этом iPhone")
        XCTAssertEqual(Set(merged.order),Set(incoming.order))
    }
}
