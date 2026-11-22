import XCTest
@testable import EntrixyCore

final class AndroidPassedAccessTests: XCTestCase {
    private let group = String(repeating:"G",count:22)
    private let secret = Data(repeating:41,count:32)
    private func invite(_ byte: UInt8 = 11, server: String = "sender.invalid") throws -> GuestInvite {
        try GuestInvite.parse("https://" + server + "/key#" + GuestCrypto.base64URL(Data(repeating:byte,count:24)) + GuestCrypto.base64URL(Data(repeating:7,count:32)))
    }
    private func document() throws -> AndroidBackupDocument {
        let first = try invite(), second = try invite(12)
        let keys: [[String:Any]] = [["id":3,"host":first.server,"key":first.userKey],["id":4,"host":second.server,"key":second.userKey]]
        let fields = ["backup_src_seed":String(repeating:"ab",count:32),"guest_keys":String(decoding:try JSONSerialization.data(withJSONObject:keys),as:UTF8.self),"passed_wk_" + group:GuestCrypto.base64URL(secret),"passed_name_" + group:"Иван"]
        let entries = fields.mapValues { ["t":"s","v":$0] }
        return try AndroidBackupDocument(JSONSerialization.data(withJSONObject:["app":"entrixy","ver":1,"created":1800000000,"device":"Public fixture","count":entries.count,"entries":entries]))
    }
    private func snapshot(_ code: Character, number: Int) throws -> PassSnapshot {
        try PassSnapshot.decode(JSONSerialization.data(withJSONObject:["objects":[],"children":[],"invites":[["grp":group,"code":String(repeating:String(code),count:22),"status":"new","objects":[try KeyObjectAccess(depth:0,pool:1).json(id:number)]]]]))
    }
    func testExistingOutgoingGroupRestoresExactSecretAndBothPartsWithoutCreateOrInventedWelcome() throws {
        let archive = try document(), first = try invite(), second = try invite(12)
        let material = try XCTUnwrap(archive.passedAccessMaterial(sourceID:first.id,groups:[group]).first)
        var restored = try PassedAccess(importing:material,source:first,snapshot:snapshot("C",number:7),defaultLabel:"Гость")
        let id = restored.id
        XCTAssertEqual(restored.label,"Иван"); XCTAssertEqual(restored.secret,secret)
        XCTAssertEqual(restored.link?.secret,secret); XCTAssertNil(restored.welcomeCipher)
        XCTAssertEqual(restored.parts[0].state,.available); XCTAssertTrue(restored.parts[0].sent)
        XCTAssertThrowsError(try restored.createRequest(part:0))
        try restored.recoverPart(source:second,snapshot:snapshot("D",number:8))
        XCTAssertEqual(restored.id,id); XCTAssertEqual(restored.parts.count,2)
        XCTAssertEqual(restored.parts.map(\.sourceID),[first.id,second.id])
        XCTAssertEqual(try JSONDecoder().decode(PassedAccess.self,from:JSONEncoder().encode(restored)),restored)
        let opposite = try PassedAccess(importing:material,source:second,snapshot:snapshot("D",number:8),defaultLabel:"Гость")
        XCTAssertEqual(opposite.id,id)
    }
    func testArchiveCannotSupplyMaterialForAnotherServerOrSigningIdentity() throws {
        let archive = try document(), foreign = try invite(server:"another.invalid")
        XCTAssertTrue(try archive.passedAccessMaterial(sourceID:foreign.id,groups:[group]).isEmpty)
        let source = try invite(), material = try XCTUnwrap(archive.passedAccessMaterial(sourceID:source.id,groups:[group]).first)
        XCTAssertThrowsError(try PassedAccess(importing:material,source:foreign,snapshot:snapshot("C",number:7),defaultLabel:"Гость"))
        XCTAssertTrue(try archive.passedAccessMaterial(sourceID:source.id,groups:[String(repeating:"X",count:22)]).isEmpty)
    }
}
