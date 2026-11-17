import XCTest
@testable import EntrixyCore

final class OwnerBLEMoveTests: XCTestCase {
    private func fixture() throws -> (OwnerAccount, OwnerAccount, OwnerObject) {
        var source = try OwnerAccount(server:"source.invalid"), target = try OwnerAccount(server:"target.invalid")
        source.credentials = try OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        target.credentials = try OwnerCredentials(deviceID:String(repeating:"c",count:32),deviceSecret:String(repeating:"d",count:64))
        for number in [7,8] {
            var pair = try BLEPairingRecord(masterKey:source.masterKey,peripheralID:UUID(),peerPublic:BLECrypto.makePair().publicKey,deviceID:UInt32(number),label:"Дверь \(number)")
            try pair.markSent()
            let head = BLECrypto.littleEndian(UInt64(number),count:4) + Data([1,0,0,0]), secret = try pair.secret(masterKey:source.masterKey)
            try pair.confirm(advertisement:head + BLECrypto.hmac(secret,head).prefix(8),masterKey:source.masterKey)
            var object = try OwnerObject(pairing:pair,masterKey:source.masterKey)
            object.numberID = number; object.revision = 1; object.pending = nil; object.available = true
            pair.objectID = object.id; source.objects = (source.objects ?? []) + [object]; source.blePairings = (source.blePairings ?? []) + [pair]
        }
        var key = try OwnerIssuedKey(owner:source,label:"Гость",numberIDs:[7,8],welcome:"",nativeOnly:false,confirmation:false)
        key.keyID = 11; key.pending = nil; key.state = .active; source.issuedKeys = [key]
        return (source,target,source.objects![0])
    }
    private func snapshot(_ objects:[[String:Any]], keys:[[String:Any]] = []) throws -> OwnerSnapshot {
        try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject:["numbers":objects,"keys":keys]))
    }
    func testLostCreateReplyIsRecoveredByExactCipherWithoutAnotherCreateOrPair() throws {
        let (_,target,object) = try fixture()
        var move = try OwnerBLEMove(object:object,destination:target.server)
        let request = try JSONSerialization.jsonObject(with:move.request()) as! [String:Any]
        XCTAssertEqual(request["data_cipher"] as? String,object.cipher)
        XCTAssertNil(request["ble_secret"])
        try move.markSent()
        move = try JSONDecoder().decode(OwnerBLEMove.self,from:JSONEncoder().encode(move))
        XCTAssertThrowsError(try move.request())
        XCTAssertFalse(try move.reconcileDestination(snapshot([])))
        XCTAssertEqual(move.phase,.createSent)
        XCTAssertTrue(try move.reconcileDestination(snapshot([["id":70,"type":"ble","data_cipher":object.cipher]])))
        XCTAssertEqual(move.phase,.removePrepared); XCTAssertEqual(move.destinationNumberID,70)
        let delete = try JSONSerialization.jsonObject(with:move.request()) as! [String:Int]
        XCTAssertEqual(delete,["id":7])
    }
    func testCommitPreservesRadioIdentityObjectKeyRulesPairingOrderAndOtherGuestObjects() throws {
        var (source,target,object) = try fixture()
        var template = AutomationTemplate(); template.bleEnabled = true; template.bleRadiusM = 5
        source.objects![0].localPolicy = try template.data(); object = source.objects![0]
        var move = try OwnerBLEMove(object:object,destination:target.server)
        try move.markSent(); try move.acceptedCreation(numberID:70); try move.markSent()
        let oldKey = source.issuedKeys![0], originalBundle = try oldKey.bundle(masterKey:source.masterKey)
        let sourceSnapshot = try snapshot([["id":8,"type":"ble","data_cipher":source.objects![1].cipher]],keys:[[
            "id":11,"enabled":1,"mode":"auto","number_ids":[8],"objects":[try KeyObjectAccess().json(id:8)],"bundle_cipher":oldKey.bundleCipher]])
        move.reconcileSource(sourceSnapshot); source.bleMoves = [move]
        let targetSnapshot = try snapshot([["id":70,"type":"ble","data_cipher":object.cipher,"data_cipher_revision":10]])
        let old = ObjectReference.owned(server:source.server,objectID:object.id), other = ObjectReference.owned(server:source.server,objectID:source.objects![1].id)
        let preferences = ObjectCatalogPreferences(order:[other,old])
        let (from,to,order) = try move.committed(source:source,destination:target,sourceSnapshot:sourceSnapshot,destinationSnapshot:targetSnapshot,preferences:preferences)
        let moved = try XCTUnwrap(to.objects?.first)
        XCTAssertEqual(moved.id,object.id); XCTAssertEqual(moved.numberID,70)
        XCTAssertEqual(moved.bleDeviceID,object.bleDeviceID); XCTAssertEqual(moved.cipher,object.cipher)
        XCTAssertEqual(try GuestCrypto.decrypt(key:to.masterKey,envelope:moved.wrappedBLESecret!),try GuestCrypto.decrypt(key:source.masterKey,envelope:object.wrappedBLESecret!))
        XCTAssertEqual(try GuestCrypto.decrypt(key:to.masterKey,envelope:moved.wrappedKey),try GuestCrypto.decrypt(key:source.masterKey,envelope:object.wrappedKey))
        XCTAssertEqual(moved.localPolicy,object.localPolicy)
        XCTAssertEqual(to.blePairings?.first?.packet,source.blePairings?.first?.packet)
        XCTAssertEqual(to.blePairings?.first?.objectID,object.id)
        XCTAssertEqual(from.objects?.map(\.numberID),[8]); XCTAssertEqual(from.bleArchivedObjects?.first?.id,object.id)
        XCTAssertTrue(from.bleMoves?.isEmpty == true)
        XCTAssertEqual(order.order,[other,.owned(server:target.server,objectID:object.id)])
        let current = try XCTUnwrap(from.issuedKeys?.first)
        XCTAssertEqual(current.wrappedSecrets,oldKey.wrappedSecrets); XCTAssertEqual(current.guestID,oldKey.guestID)
        XCTAssertEqual(current.numberIDs,[8])
        let remaining = try current.bundle(masterKey:from.masterKey)["ble"] as! [[String:Any]]
        let original = originalBundle["ble"] as! [[String:Any]]
        XCTAssertEqual(try BLEGuestGrant(row:remaining[0]),try BLEGuestGrant(row:original[1]))
        XCTAssertEqual(from.bleRevocations?.first?.revoked,true)
        XCTAssertEqual(from.bleRevocations?.first?.deviceID,object.bleDeviceID)
    }
    func testSentDeleteWaitsForActualAbsenceAndRollbackNeverTouchesPhysicalSecret() throws {
        let (source,target,object) = try fixture(); var move = try OwnerBLEMove(object:object,destination:target.server)
        try move.markSent(); try move.acceptedCreation(numberID:70); try move.markSent()
        move.reconcileSource(try snapshot([["id":7,"type":"ble","data_cipher":object.cipher]]))
        XCTAssertEqual(move.phase,.removeSent)
        try move.rollback(); XCTAssertEqual(try JSONSerialization.jsonObject(with:move.request()) as? [String:Int],["id":70])
        XCTAssertEqual(source.objects?.first?.wrappedBLESecret,object.wrappedBLESecret)
        XCTAssertNil(source.bleRevocations)
        XCTAssertThrowsError(try move.committed(source:source,destination:target,sourceSnapshot:snapshot([]),destinationSnapshot:snapshot([]),preferences:.init()))
    }
    func testRemovingLastMovedScopeDoesNotRegenerateOrPermitIssuingAnEmptyNewKey() throws {
        let (source,_,_) = try fixture()
        var key = source.issuedKeys![0]; let identity = key.wrappedSecrets
        try key.removeMovedObject(7,masterKey:source.masterKey)
        key.pending = nil
        try key.removeMovedObject(8,masterKey:source.masterKey)
        try key.validate(masterKey:source.masterKey)
        XCTAssertEqual(key.numberIDs,[]); XCTAssertEqual(key.wrappedSecrets,identity)
        let bundle = try key.bundle(masterKey:source.masterKey)
        XCTAssertEqual((bundle["ble"] as? [[String:Any]])?.count,0)
        XCTAssertThrowsError(try OwnerIssuedKey(owner:source,label:"Пустой",numberIDs:[],welcome:"",nativeOnly:false,confirmation:false))
    }
}
