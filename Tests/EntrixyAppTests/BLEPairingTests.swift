import XCTest
import EntrixyCore
@testable import Entrixy

private final class PairingStorage: StateStorage {
    var state: SavedState?
    var writes = 0
    var failAt: Int?
    init() throws {
        var owner = try OwnerAccount(server: "https://fixture.invalid")
        owner.credentials = try OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64))
        state = SavedState(identity: Data(repeating: 41, count: 32), guests: [], owners: [owner])
    }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        writes += 1
        if writes == failAt { throw KeychainStore.Failure(status: -1) }
        self.state = state
    }
}
@MainActor private final class PairingChannel: BLEChannel {
    let pair = BLECrypto.makePair()
    let results = AsyncThrowingStream<UInt8, Error> { $0.finish() }
    var beforeWrite: ((Data) throws -> Void)?
    var writes = 0
    var closed = false
    var lostReply = false
    func enableResults() async throws -> Bool { false }
    func read(_ characteristic: String) async throws -> Data { pair.publicKey }
    func write(_ data: Data, to characteristic: String) async throws {
        XCTAssertEqual(characteristic, BLECrypto.pairDoneCharacteristic)
        writes += 1; try beforeWrite?(data)
        if lostReply { throw URLError(.networkConnectionLost) }
    }
    func close() async { closed = true }
}
@MainActor private final class PairingCentral: BLECentralTransport {
    let channel = PairingChannel()
    let id = UUID()
    var advertisements: [BLEDiscovery] = []
    var connections = 0
    var stopped = false
    var scanHook: (() -> Void)?
    func scan(seconds: TimeInterval) async throws -> [BLEDiscovery] { scanHook?(); return advertisements }
    func connect(_ discoveryID: UUID, pairing: Bool) async throws -> any BLEChannel {
        connections += 1; XCTAssertEqual(discoveryID, id); XCTAssertTrue(pairing); return channel
    }
    func stop() { stopped = true }
}
@MainActor final class BLEPairingTests: XCTestCase {
    func testSecretAndSentPersistBeforeOneWriteAndLostReplyDoesNotRePair() async throws {
        let storage = try PairingStorage(), central = PairingCentral()
        let originalIdentity = storage.state!.identity
        let app = AppModel(storage: storage)
        let model = BLEPairingModel(app: app, transport: central)
        central.channel.lostReply = true
        central.channel.beforeWrite = { packet in
            let record = try XCTUnwrap(storage.state?.owners?.first?.blePairings?.first)
            XCTAssertEqual(record.phase, .sent); XCTAssertEqual(record.packet, packet)
            let owner = storage.state!.owners!.first!
            XCTAssertEqual(try record.secret(masterKey: owner.masterKey).count, 32)
        }
        await model.pair(discoveryID: central.id, server: "fixture.invalid", label: "Ворота")
        XCTAssertEqual(central.channel.writes, 1); XCTAssertTrue(central.channel.closed)
        let restored = AppModel(storage: storage)
        let recovery = BLEPairingModel(app: restored, transport: central)
        let record = try XCTUnwrap(restored.owners.first?.blePairings?.first)
        await recovery.pair(discoveryID: central.id, server: "fixture.invalid", label: "Ворота")
        await recovery.sendPrepared(pairingID: record.id, server: "fixture.invalid")
        XCTAssertEqual(central.connections, 1); XCTAssertEqual(central.channel.writes, 1)
        let owner = restored.owners[0]
        let head = Data((0..<4).map { UInt8(truncatingIfNeeded: record.deviceID >> ($0 * 8)) }) + Data([1,0,0,0])
        // Independent authenticated advertising via the public fixture helper:
        // ownerFire returns nonce8 + HMAC(secret,nonce)16; advertisements use first8.
        let packet = try BLECrypto.ownerFire(ownerSecret: record.secret(masterKey: owner.masterKey), nonce: head)
        central.advertisements = [BLEDiscovery(id: UUID(), name: "Different name", rssi: -55, manufacturerPayload: head + packet.dropFirst(8).prefix(8))]
        await recovery.check(pairingID: record.id, server: "fixture.invalid")
        XCTAssertEqual(restored.owners[0].blePairings?.first?.phase, .confirmed)
        XCTAssertEqual(storage.state?.identity, originalIdentity)
        XCTAssertEqual(central.channel.writes, 1)
        XCTAssertTrue(restored.journal.isEmpty)
    }
    func testStorageFailurePreventsPairWriteAndPreparedUsesSameKey() async throws {
        let storage = try PairingStorage(), central = PairingCentral()
        let app = AppModel(storage: storage)
        let live = BLEPairingModel(app: app, transport: central)
        storage.failAt = 2
        await live.pair(discoveryID: central.id, server: "fixture.invalid", label: "Дверь")
        XCTAssertEqual(central.channel.writes, 0)
        let prepared = try XCTUnwrap(storage.state?.owners?.first?.blePairings?.first)
        XCTAssertEqual(prepared.phase, .prepared)
        storage.failAt = nil
        await live.sendPrepared(pairingID: prepared.id, server: "fixture.invalid")
        XCTAssertEqual(central.channel.writes, 1)
        XCTAssertEqual(storage.state?.owners?.first?.blePairings?.first?.packet, prepared.packet)
        XCTAssertEqual(storage.state?.owners?.first?.blePairings?.first?.wrappedSecret, prepared.wrappedSecret)
    }
    func testBackgroundInvalidatesScanAndNeverWrites() async throws {
        let storage = try PairingStorage(), central = PairingCentral(), app = AppModel(storage: try PairingStorage())
        let model = BLEPairingModel(app: app, transport: central)
        central.scanHook = { model.suspend() }
        central.advertisements = [BLEDiscovery(id: central.id, name: "Entrixy", rssi: -40, manufacturerPayload: nil)]
        await model.scan()
        XCTAssertTrue(model.discoveries.isEmpty); XCTAssertFalse(model.busy)
        XCTAssertTrue(central.stopped); XCTAssertEqual(central.channel.writes, 0)
        XCTAssertNil(storage.state?.owners?.first?.blePairings)
    }
}
