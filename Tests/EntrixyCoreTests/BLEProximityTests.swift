import XCTest
@testable import EntrixyCore

final class BLEProximityTests: XCTestCase {
    private let secret = Data(repeating:9,count:32)
    private func payload(counter: UInt32 = 1, sleep: UInt8 = 0, state: UInt8 = 0) throws -> Data {
        let head = BLECrypto.littleEndian(123,count:4)+BLECrypto.littleEndian(UInt64(counter),count:4)
        let metadata = Data([sleep,0,0,0,0])
        var packet = head + BLECrypto.hmac(secret,head+metadata).prefix(8) + metadata
        let key = try BLECrypto.stateKey(ownerSecret:secret)
        let encrypted = state ^ key[Int(counter & 15)]
        packet.append(encrypted)
        packet.append(BLECrypto.hmac(key,BLECrypto.littleEndian(UInt64(counter),count:4)+Data([encrypted])).prefix(2))
        return packet
    }
    private func grant(deviceID: Int = 123) throws -> BLEGuestGrant {
        let token = try BLECrypto.token(guestID:2,validUntil:1000)
        return try BLEGuestGrant(row:["id":7,"did":deviceID,"token":token.base64EncodedString(),
            "sig":BLECrypto.ownerSignature(ownerSecret:secret,token:token).base64EncodedString(),
            "gkey":BLECrypto.guestKey(ownerSecret:secret,guestID:2).base64EncodedString(),
            "kstate":BLECrypto.stateKey(ownerSecret:secret).base64EncodedString()])
    }
    func testOnlyScopedAuthenticatedAndUnexpiredGuestFramesCanBeProximityEvidence() throws {
        let packet = try payload(sleep:10,state:1)
        let owner = try AuthenticatedBLEObservation.owner(payload:packet,secret:secret)
        XCTAssertEqual(owner.deviceID,123); XCTAssertEqual(owner.sleepSeconds,10); XCTAssertTrue(owner.openish)
        let guest = try AuthenticatedBLEObservation.guest(payload:packet,grant:grant(),epoch:100)
        XCTAssertEqual(guest.position,"open"); XCTAssertNil(guest.sleepSeconds)
        XCTAssertThrowsError(try AuthenticatedBLEObservation.guest(payload:packet,grant:grant(deviceID:124),epoch:100))
        XCTAssertThrowsError(try AuthenticatedBLEObservation.guest(payload:packet,grant:grant(),epoch:1001))
        var forged = packet; forged[22] ^= 1
        XCTAssertThrowsError(try AuthenticatedBLEObservation.owner(payload:forged,secret:secret))
        XCTAssertThrowsError(try AuthenticatedBLEObservation.guest(payload:forged,grant:grant(),epoch:100))
        forged = packet; forged[8] ^= 1
        XCTAssertThrowsError(try AuthenticatedBLEObservation.owner(payload:forged,secret:secret))
    }
    func testOpenAndOpeningAreNeverSafeForAnAutomaticToggle() throws {
        for (bits,position,openish) in [(UInt8(0),"closed",false),(1,"open",true),(0x41,"opening",true),(0x40,"closing",false),(0x80,"none",false)] {
            let observation = try AuthenticatedBLEObservation.owner(payload:payload(state:bits),secret:secret)
            XCTAssertEqual(observation.position ?? "none",position); XCTAssertEqual(observation.openish,openish)
        }
    }
    func testDebounceAndActualRadioGapUseTrustedControllerSleep() throws {
        let observation = try AuthenticatedBLEObservation.owner(payload:payload(sleep:10),secret:secret)
        var runtime = BLEProximityRuntime()
        XCTAssertFalse(runtime.receive(key:"a",observation:observation,rssi:-60,now:0))
        XCTAssertTrue(runtime.sample("a",at:0)!.near(radiusM:3,at:0))
        XCTAssertFalse(runtime.receive(key:"a",observation:observation,rssi:-100,now:1))
        XCTAssertEqual(runtime.sample("a",at:1)?.rssi,-60)
        XCTAssertFalse(runtime.receive(key:"a",observation:observation,rssi:-100,now:5))
        XCTAssertEqual(runtime.sample("a",at:5)?.rssi,-100)
        XCTAssertFalse(runtime.receive(key:"a",observation:observation,rssi:-60,now:50))
        XCTAssertTrue(runtime.receive(key:"a",observation:observation,rssi:-60,now:105))
        XCTAssertEqual(BLEProximityRuntime.window(0),5); XCTAssertEqual(BLEProximityRuntime.window(10),55)
        XCTAssertEqual(BLEProximityRuntime.window(255),60); XCTAssertEqual(BLEProximityRuntime.window(nil),60)
    }
    func testBackgroundAndOwnGATTGapsAreNotEvidenceOfLeavingTheGate() throws {
        let observation = try AuthenticatedBLEObservation.owner(payload:payload(),secret:secret)
        var runtime = BLEProximityRuntime()
        _ = runtime.receive(key:"a",observation:observation,rssi:-60,now:0)
        runtime.suspend()
        XCTAssertFalse(runtime.receive(key:"a",observation:observation,rssi:-60,now:100))
        XCTAssertTrue(runtime.receive(key:"a",observation:observation,rssi:-60,now:106))
        XCTAssertNil(runtime.sample("a",at:111)); XCTAssertFalse(runtime.receive(key:"a",observation:observation,rssi:127,now:112))
    }
    func testOldUnsignedSleepCannotShortenTheRearmWindow() throws {
        let head = BLECrypto.littleEndian(123,count:4)+BLECrypto.littleEndian(1,count:4)
        let packet = head+BLECrypto.hmac(secret,head).prefix(8)+Data([0])
        let observation = try AuthenticatedBLEObservation.owner(payload:packet,secret:secret)
        XCTAssertNil(observation.sleepSeconds); XCTAssertNil(observation.position)
        XCTAssertThrowsError(try AuthenticatedBLEObservation.guest(payload:packet,grant:grant(),epoch:100))
    }
}
