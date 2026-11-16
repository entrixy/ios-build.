import XCTest
import EntrixyCore
@testable import Entrixy

private final class GuestBLEStorage: StateStorage {
    var state: SavedState?
    var failing = false
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if failing { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}
@MainActor private final class GuestBLEChannel: BLEChannel {
    let results: AsyncThrowingStream<UInt8, Error>
    private let output: AsyncThrowingStream<UInt8, Error>.Continuation
    let timeNonce = Data([1,2,3,4,5,6,7,8]), fireNonce = Data([11,12,13,14,15,16,17,18])
    var reads = 0
    var writes: [(String, Data)] = []
    var timeResult: UInt8 = 0x11
    var fireResult: UInt8 = 0
    var beforeFire: (() throws -> Void)?
    var lostFireReply = false
    init() {
        var sink: AsyncThrowingStream<UInt8, Error>.Continuation!
        results = AsyncThrowingStream { sink = $0 }; output = sink
    }
    func enableResults() async throws -> Bool { true }
    func read(_ characteristic: String) async throws -> Data {
        XCTAssertEqual(characteristic, BLECrypto.nonceCharacteristic)
        reads += 1; return reads == 1 ? timeNonce : fireNonce
    }
    func write(_ data: Data, to characteristic: String) async throws {
        if characteristic == BLECrypto.fireCharacteristic { try beforeFire?() }
        writes.append((characteristic, data))
        if characteristic == BLECrypto.revokeCharacteristic { output.yield(0x40) }
        else if characteristic == BLECrypto.timeCharacteristic { output.yield(timeResult) }
        else {
            if lostFireReply { throw URLError(.networkConnectionLost) }
            output.yield(0x11); output.yield(fireResult)
        }
    }
    func close() async { output.finish() }
}
@MainActor private final class GuestBLECentral: BLECentralTransport {
    let channel = GuestBLEChannel()
    var scans = 0
    var beforeScanReturns: (() -> Void)?
    func scan(seconds: TimeInterval) async throws -> [BLEDiscovery] {
        scans += 1; beforeScanReturns?()
        return [BLEDiscovery(id: UUID(), name: "Entrixy", rssi: -50,
            manufacturerPayload: Data([123,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0]))]
    }
    func connect(_ discoveryID: UUID, pairing: Bool) async throws -> any BLEChannel { XCTAssertFalse(pairing); return channel }
    func stop() {}
}
@MainActor final class BLEGuestControlTests: XCTestCase {
    private func fixture(auth: Bool = false, expired: Bool = false) throws -> (GuestBLEStorage, GuestBLECentral, AppModel, SavedGuest, BLEGuestGrant) {
        let storage = GuestBLEStorage(), central = GuestBLECentral()
        let invite = try GuestInvite.parse("https://fixture.invalid/key#" + String(repeating: "A", count: 32) + GuestCrypto.base64URL(Data(repeating: 9, count: 32)))
        let epoch = UInt64(Date().timeIntervalSince1970), expiry = UInt32(epoch + (expired ? 0 : 3600)) - (expired ? 1 : 0)
        let ownerSecret = Data(repeating: 7, count: 32)
        let token = try BLECrypto.token(guestID: 9, validUntil: expiry)
        let row: [String: Any] = ["id": 7, "did": 123, "label": "Bluetooth-ворота",
            "token": token.base64EncodedString(),
            "sig": try BLECrypto.ownerSignature(ownerSecret: ownerSecret, token: token).base64EncodedString(),
            "gkey": try BLECrypto.guestKey(ownerSecret: ownerSecret, guestID: 9).base64EncodedString(),
            "kstate": try BLECrypto.stateKey(ownerSecret: ownerSecret).base64EncodedString(),
            "valid_until": expiry, "tpl": ["confirm_on": true, "auth_on": auth, "auth": "pin"]]
        let bundle = try JSONSerialization.data(withJSONObject: ["ble": [row]])
        let snapshot = Data(#"{"numbers":[{"id":7,"type":"ble"}]}"#.utf8)
        var guest = SavedGuest(invite: invite, objects: try GuestObjects.decode(bundle: bundle, snapshot: snapshot))
        guest.bleCache = try GuestBLECache(bundle: bundle, snapshot: snapshot, key: invite.bundleKey, epoch: epoch)
        storage.state = SavedState(identity: Data(repeating: 4, count: 32), guests: [guest])
        let app = AppModel(storage: storage)
        app.bleGuestControl = BLEGuestControlModel(app: app, transport: central)
        return (storage, central, app, guest, try BLEGuestGrant(row: row))
    }
    func testOfflineGuestHasOneAuthenticatedFireAfterClockAndDurableJournal() async throws {
        let (storage, central, app, guest, grant) = try fixture()
        XCTAssertEqual(app.connection(for: guest.id), .offline)
        let intent = try XCTUnwrap(app.actionIntent(guestID: guest.id, object: guest.objects[0]))
        XCTAssertEqual(intent.title, "Подать импульс / переключить")
        central.channel.beforeFire = {
            XCTAssertEqual(storage.state?.journal?.count, 1)
            XCTAssertEqual(storage.state?.guests.first?.bleCache?.usedProofs.count, 1)
        }
        await app.execute(intent)
        XCTAssertEqual(central.channel.writes.map(\.0), [BLECrypto.timeCharacteristic, BLECrypto.fireCharacteristic])
        XCTAssertEqual(central.channel.writes[1].1, try BLECrypto.guestFire(token: grant.token,
            ownerSignature: grant.ownerSignature, guestKey: grant.guestKey, nonce: central.channel.fireNonce))
        XCTAssertEqual(app.journal.first?.result, "Контроллер принял команду")
        XCTAssertEqual(app.journal.first?.level, "success")
        XCTAssertEqual(storage.state?.identity, Data(repeating: 4, count: 32))
        XCTAssertFalse(app.bleGuestControl.busy)
    }
    func testPINIsRequiredBeforeAnyBLEOperation() async throws {
        let (_, central, app, guest, _) = try fixture(auth: true)
        let intent = try XCTUnwrap(app.actionIntent(guestID: guest.id, object: guest.objects[0]))
        // Calling the coordinator directly cannot bypass AppModel authorization.
        await app.bleGuestControl.execute(intent)
        await app.execute(intent)
        XCTAssertEqual(central.scans, 0); XCTAssertTrue(central.channel.writes.isEmpty)
        try await app.setActionCode("1234")
        let accepted = try await app.authorizeCode("1234", intent: intent)
        XCTAssertTrue(accepted)
        await app.execute(intent)
        XCTAssertEqual(central.channel.writes.filter { $0.0 == BLECrypto.fireCharacteristic }.count, 1)
    }
    func testExpiredOrRemovedKeyNeverFiresAndClockRefusalIsNotActionHistory() async throws {
        let (_, expiredCentral, expiredApp, expiredGuest, _) = try fixture(expired: true)
        XCTAssertNil(expiredApp.actionIntent(guestID: expiredGuest.id, object: expiredGuest.objects[0]))
        XCTAssertEqual(expiredCentral.scans, 0)
        let (_, central, app, guest, _) = try fixture()
        central.channel.timeResult = 0x13
        let intent = try XCTUnwrap(app.actionIntent(guestID: guest.id, object: guest.objects[0]))
        await app.execute(intent)
        XCTAssertEqual(central.channel.writes.map(\.0), [BLECrypto.timeCharacteristic])
        XCTAssertTrue(app.journal.isEmpty)
        let (_, removal, other, target, _) = try fixture()
        let pending = try XCTUnwrap(other.actionIntent(guestID: target.id, object: target.objects[0]))
        removal.beforeScanReturns = { other.removeKey(target.id) }
        await other.execute(pending)
        XCTAssertTrue(removal.channel.writes.isEmpty); XCTAssertTrue(other.journal.isEmpty)
    }
    func testSaveFailureBlocksFireAndLostFireReplyIsNotRetried() async throws {
        let (storage, central, app, guest, _) = try fixture()
        storage.failing = true
        let intent = try XCTUnwrap(app.actionIntent(guestID: guest.id, object: guest.objects[0]))
        await app.execute(intent)
        XCTAssertEqual(central.channel.writes.map(\.0), [BLECrypto.timeCharacteristic])
        XCTAssertTrue(app.journal.isEmpty)
        let (_, lost, other, target, _) = try fixture()
        lost.channel.lostFireReply = true
        let pending = try XCTUnwrap(other.actionIntent(guestID: target.id, object: target.objects[0]))
        await other.execute(pending)
        XCTAssertEqual(lost.channel.writes.filter { $0.0 == BLECrypto.fireCharacteristic }.count, 1)
        XCTAssertEqual(other.journal.first?.level, "warning")
        XCTAssertTrue(other.journal.first?.result.contains("неизвестен") == true)
    }
    func testGuestCarriesSignedRevocationBeforeTimeAndFireWithoutAddingMaintenanceJournal() async throws {
        let (storage, central, app, guest, _) = try fixture()
        let record = try BLERevocation(deviceID: 123, guestID: 10, version: 100, revoked: true, ownerSecret: Data(repeating: 7, count: 32))
        let data = try JSONSerialization.data(withJSONObject: ["type": "ble_revokes", "items": [record.json]])
        try app.receiveBLERevocations(data, guestID: guest.id)
        XCTAssertTrue(app.journal.isEmpty)
        XCTAssertEqual(storage.state?.guests.first?.bleCache?.revocations?.first?.version, 100)
        let intent = try XCTUnwrap(app.actionIntent(guestID: guest.id, object: guest.objects[0]))
        await app.execute(intent)
        XCTAssertEqual(central.channel.writes.map(\.0), [BLECrypto.revokeCharacteristic, BLECrypto.timeCharacteristic, BLECrypto.fireCharacteristic])
        XCTAssertEqual(central.channel.writes.first?.1, record.frame)
        XCTAssertEqual(storage.state?.guests.first?.bleCache?.revocations?.first?.applied, true)
        XCTAssertEqual(app.journal.count, 1)
        XCTAssertEqual(app.journal.first?.result, "Контроллер принял команду")
    }

    func testChangedLocalRulesInvalidatePendingBluetoothAuthorization() async throws {
        let (_, central, app, guest, _) = try fixture()
        let object = guest.objects[0]
        let intent = try XCTUnwrap(app.actionIntent(guestID: guest.id, object: object))
        let context = try app.automationContext(.object(.received(guestID: guest.id, objectID: object.id)))
        var updated = context.template; updated.authEnabled = true; updated.authMode = "pin"
        XCTAssertTrue(app.saveAutomation(context, template: updated))
        XCTAssertThrowsError(try app.guestBLEMaterial(intent))
        await app.execute(intent)
        XCTAssertTrue(central.channel.writes.isEmpty)
        XCTAssertTrue(app.journal.isEmpty)
        let fresh = try XCTUnwrap(app.actionIntent(guestID: guest.id, object: object))
        XCTAssertEqual(fresh.policy.authentication, "pin")
        XCTAssertNotEqual(fresh.policy.template, intent.policy.template)
    }

}
