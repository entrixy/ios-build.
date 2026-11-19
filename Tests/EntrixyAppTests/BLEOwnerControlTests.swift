import XCTest
import EntrixyCore
@testable import Entrixy

private final class BLEOwnerStorage: StateStorage {
    var state: SavedState?
    var failing = false
    var afterSave: ((SavedState) -> Void)?
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws {
        if failing { throw KeychainStore.Failure(status: -1) }
        self.state = state
        afterSave?(state)
    }
}
@MainActor private final class OwnerBLEChannel: BLEChannel {
    let nonce = Data([1,2,3,4,5,6,7,8])
    let results: AsyncThrowingStream<UInt8, Error>
    private let output: AsyncThrowingStream<UInt8, Error>.Continuation
    var writes: [Data] = []
    var beforeWrite: (() throws -> Void)?
    var beforeNonce: (() -> Void)?
    var lostReply = false
    var hasResults = true
    var result: UInt8 = 0
    var closed = false
    var revokeResult: UInt8 = 0x40
    var beforeRevoke: (() throws -> Void)?
    var lostRevokeReply = false
    init() {
        var sink: AsyncThrowingStream<UInt8, Error>.Continuation!
        results = AsyncThrowingStream { sink = $0 }; output = sink
    }
    func enableResults() async throws -> Bool { hasResults }
    func read(_ characteristic: String) async throws -> Data {
        XCTAssertEqual(characteristic, BLECrypto.nonceCharacteristic); beforeNonce?(); return nonce
    }
    func write(_ data: Data, to characteristic: String) async throws {
        if characteristic == BLECrypto.revokeCharacteristic {
            try beforeRevoke?(); writes.append(data)
            if lostRevokeReply { throw URLError(.networkConnectionLost) }
            output.yield(revokeResult)
            return
        }
        XCTAssertEqual(characteristic, BLECrypto.fireCharacteristic)
        try beforeWrite?(); writes.append(data)
        if lostReply { throw URLError(.networkConnectionLost) }
        output.yield(0x10) // TIME result must never become a FIRE result.
        output.yield(result)
    }
    func close() async { closed = true; output.finish() }
}
@MainActor private final class OwnerBLECentral: BLECentralTransport {
    let channel = OwnerBLEChannel()
    var discoveries: [BLEDiscovery] = []
    var beforeReadReturn: (() -> Void)?
    var connects = 0
    func scan(seconds: TimeInterval) async throws -> [BLEDiscovery] { beforeReadReturn?(); return discoveries }
    func connect(_ discoveryID: UUID, pairing: Bool) async throws -> any BLEChannel { XCTAssertFalse(pairing); connects += 1; return channel }
    func stop() {}
}
@MainActor final class BLEOwnerControlTests: XCTestCase {
    func testKnownOwnershipLossDuringScanCannotConnectOrFire() async throws {
        let (storage,central,app,object,_) = try fixture()
        app.bleControl = BLEOwnerControlModel(app:app,transport:central); defer { app.suspend() }
        central.beforeReadReturn = { app.recordOwnerAccessLoss("fixture.invalid") }
        await app.bleControl.execute(server:"fixture.invalid",objectID:object.id)
        XCTAssertEqual(central.connects,0); XCTAssertTrue(central.channel.writes.isEmpty); XCTAssertTrue(app.journal.isEmpty)
        XCTAssertFalse(app.ownerAccessIsUsable("fixture.invalid")); XCTAssertEqual(storage.state?.owners?.first?.ownershipLost,true)
        XCTAssertTrue(app.controlObjects.isEmpty)
    }
    func testKnownOwnershipLossAfterNonceStillBlocksFireWhenSavingLossFails() async throws {
        let (storage,central,app,object,_) = try fixture()
        app.bleControl = BLEOwnerControlModel(app:app,transport:central); defer { app.suspend() }
        central.channel.beforeNonce = { storage.failing = true; app.recordOwnerAccessLoss("fixture.invalid") }
        await app.bleControl.execute(server:"fixture.invalid",objectID:object.id)
        XCTAssertEqual(central.connects,1); XCTAssertTrue(central.channel.writes.isEmpty); XCTAssertTrue(app.journal.isEmpty)
        XCTAssertFalse(app.ownerAccessIsUsable("fixture.invalid")); XCTAssertEqual(app.owners[0].ownershipLost,true)
        storage.failing = false
        XCTAssertTrue(app.selectOwnerServer("entrixy.com"))
        let restarted = AppModel(storage:storage); defer { restarted.suspend() }
        XCTAssertFalse(restarted.ownerAccessIsUsable("fixture.invalid")); XCTAssertNil(restarted.ownerActionIntent(server:"fixture.invalid",objectID:object.id))
    }
    private func fixture(template: AutomationTemplate? = nil) throws -> (BLEOwnerStorage, OwnerBLECentral, AppModel, OwnerObject, Data) {
        let storage = BLEOwnerStorage(), central = OwnerBLECentral()
        var owner = try OwnerAccount(server: "https://fixture.invalid")
        owner.credentials = try OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64))
        let peer = BLECrypto.makePair()
        var pair = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: UUID(), peerPublic: peer.publicKey, deviceID: 123, label: "Ворота")
        try pair.markSent()
        let secret = try pair.secret(masterKey: owner.masterKey)
        let head = Data([123,0,0,0,1,0,0,0])
        let signed = try BLECrypto.ownerFire(ownerSecret: secret, nonce: head)
        let payload = head + signed.dropFirst(8).prefix(8)
        try pair.confirm(advertisement: payload, masterKey: owner.masterKey)
        var object = try OwnerObject(pairing: pair, masterKey: owner.masterKey)
        object.localPolicy = try template?.data()
        object.numberID = 7; object.pending = nil; object.available = true
        owner.objects = [object]
        storage.state = SavedState(identity: Data(repeating: 4, count: 32), guests: [], owners: [owner])
        central.discoveries = [BLEDiscovery(id: UUID(), name: "Entrixy", rssi: -45, manufacturerPayload: payload)]
        return (storage, central, AppModel(storage: storage), object, secret)
    }
    func testAuthenticatedPassiveProximityFiresOnceAndKeepsLatchAcrossRelaunch() async throws {
        var template = AutomationTemplate(); template.bleEnabled = true
        let (storage,central,app,object,_) = try fixture(template:template)
        app.bleControl = BLEOwnerControlModel(app:app,transport:central)
        defer { app.suspend() }
        let target = ObjectReference.owned(server:"fixture.invalid",objectID:object.id)
        app.automation.receiveBLE(try XCTUnwrap(central.discoveries[0].manufacturerPayload),rssi:-45)
        let proof = try XCTUnwrap(app.conditionReadiness(target))
        XCTAssertTrue(proof.ready)
        await app.performAutomaticAction(.owned(app.owners[0],object),readiness:proof)
        XCTAssertEqual(central.channel.writes.count,1)
        XCTAssertTrue(app.bleAutomationDisarmed.contains(target.id))
        let next = try XCTUnwrap(app.conditionReadiness(target))
        XCTAssertFalse(next.ready)
        await app.performAutomaticAction(.owned(app.owners[0],object),readiness:next)
        XCTAssertEqual(central.channel.writes.count,1)
        let restarted = AppModel(storage:storage)
        defer { restarted.suspend() }
        restarted.automation.receiveBLE(try XCTUnwrap(central.discoveries[0].manufacturerPayload),rssi:-45)
        XCTAssertFalse(try XCTUnwrap(restarted.conditionReadiness(target)).ready)
        XCTAssertEqual(restarted.journal.count,1)
    }
    func testBackgroundAutomaticBLEFiresOnceWithoutEnablingManualOrSettingsAccess() async throws {
        var template = AutomationTemplate(); template.bleEnabled = true
        let (storage,central,app,object,_) = try fixture(template:template)
        app.bleControl = BLEOwnerControlModel(app:app,transport:central); defer { app.suspend() }
        let entry = CatalogObject.owned(app.owners[0],object), target = entry.target
        app.automation.receiveBLE(try XCTUnwrap(central.discoveries[0].manufacturerPayload),rssi:-45)
        let proof = try XCTUnwrap(app.conditionReadiness(target)); XCTAssertTrue(proof.ready)
        try await app.setActionCode("1234")
        let locked = try await app.configureEntryLock(enabled:true,biometric:false,code:"")
        XCTAssertTrue(locked); app.entryDidBackground(now:100); app.checkEntryLock(now:161)
        XCTAssertTrue(app.appLocked)
        app.suspend(preserveAutomation:true); app.backgroundMonitoring = true
        let scope = try XCTUnwrap(app.beginBackgroundAutomatic(entry,readiness:proof,duration:8))
        XCTAssertFalse(app.canManageGuestAccess); XCTAssertFalse(app.isForeground)
        XCTAssertNil(app.ownerActionIntent(server:"fixture.invalid",objectID:object.id))
        XCTAssertFalse(app.saveOwnerActionPolicy(server:"fixture.invalid",objectID:object.id,expected:object.localPolicy,confirmation:false,authentication:"none"))
        await app.performAutomaticAction(entry,readiness:proof)
        XCTAssertEqual(central.channel.writes.count,1); XCTAssertEqual(storage.state?.journal?.count,1)
        XCTAssertTrue(app.bleAutomationDisarmed.contains(target.id))
        app.endBackgroundAutomatic(scope)
        await app.performAutomaticAction(entry,readiness:proof)
        XCTAssertEqual(central.channel.writes.count,1); XCTAssertFalse(app.canManageGuestAccess)
        XCTAssertTrue(app.appLocked)
    }
    func testBackgroundWindowRevokedAfterNonceCannotFireOrWriteJournalAndCannotRetry() async throws {
        var template = AutomationTemplate(); template.bleEnabled = true
        let (_,central,app,object,_) = try fixture(template:template)
        app.bleControl = BLEOwnerControlModel(app:app,transport:central); defer { app.suspend() }
        let entry = CatalogObject.owned(app.owners[0],object)
        app.automation.receiveBLE(try XCTUnwrap(central.discoveries[0].manufacturerPayload),rssi:-45)
        let proof = try XCTUnwrap(app.conditionReadiness(entry.target))
        app.suspend(preserveAutomation:true); app.backgroundMonitoring = true
        let scope = try XCTUnwrap(app.beginBackgroundAutomatic(entry,readiness:proof,duration:8))
        central.channel.beforeNonce = { app.endBackgroundAutomatic(scope) }
        await app.performAutomaticAction(entry,readiness:proof)
        XCTAssertEqual(central.connects,1); XCTAssertTrue(central.channel.writes.isEmpty); XCTAssertTrue(app.journal.isEmpty)
        XCTAssertTrue(app.bleAutomationDisarmed.contains(entry.target.id))
        await app.performAutomaticAction(entry,readiness:proof)
        XCTAssertEqual(central.connects,1)
    }
    func testWindowRevokedDuringDurableProofSaveCannotWriteFireAfterStorageReturns() async throws {
        var template = AutomationTemplate(); template.bleEnabled = true
        let (storage,central,app,object,_) = try fixture(template:template)
        app.bleControl = BLEOwnerControlModel(app:app,transport:central); defer { app.suspend() }
        let entry = CatalogObject.owned(app.owners[0],object)
        app.automation.receiveBLE(try XCTUnwrap(central.discoveries[0].manufacturerPayload),rssi:-45)
        let proof = try XCTUnwrap(app.conditionReadiness(entry.target))
        app.suspend(preserveAutomation:true); app.backgroundMonitoring = true
        let scope = try XCTUnwrap(app.beginBackgroundAutomatic(entry,readiness:proof,duration:8))
        storage.afterSave = { saved in
            if saved.journal?.first?.actionKey.hasPrefix("ble-owner:") == true { app.endBackgroundAutomatic(scope) }
        }
        await app.performAutomaticAction(entry,readiness:proof)
        XCTAssertEqual(central.connects,1); XCTAssertTrue(central.channel.writes.isEmpty)
        XCTAssertEqual(storage.state?.journal?.count,1)
        XCTAssertEqual(storage.state?.owners?.first?.objects?.first?.bleProofs?.count,1)
        XCTAssertTrue(app.bleAutomationDisarmed.contains(entry.target.id))
    }
    func testAutomaticBLEWithCodeOrConfirmationIsManualOnlyAsOnAndroid() async throws {
        for auth in [false,true] {
            var template = AutomationTemplate(); template.bleEnabled = true
            template.authEnabled = auth; template.confirmEnabled = !auth
            let (_,central,app,object,_) = try fixture(template:template)
            app.bleControl = BLEOwnerControlModel(app:app,transport:central)
            defer { app.suspend() }
            let entry = CatalogObject.owned(app.owners[0],object)
            app.automation.receiveBLE(try XCTUnwrap(central.discoveries[0].manufacturerPayload),rssi:-45)
            let proof = try XCTUnwrap(app.conditionReadiness(entry.target)); XCTAssertTrue(proof.ready)
            await app.performAutomaticAction(entry,readiness:proof)
            XCTAssertTrue(central.channel.writes.isEmpty); XCTAssertEqual(central.connects,0)
            XCTAssertNil(app.actionPrompt); XCTAssertTrue(app.bleAutomationDisarmed.contains(entry.target.id))
        }
    }
    func testForgedPassiveFramesAndLatchStorageFailureCannotStartGATT() async throws {
        var template = AutomationTemplate(); template.bleEnabled = true
        let (storage,central,app,object,_) = try fixture(template:template)
        app.bleControl = BLEOwnerControlModel(app:app,transport:central)
        defer { app.suspend() }
        let target = ObjectReference.owned(server:"fixture.invalid",objectID:object.id)
        app.automation.receiveBLE(Data(repeating:0,count:16),rssi:-20)
        XCTAssertFalse(try XCTUnwrap(app.conditionReadiness(target)).ready)
        XCTAssertNil(app.bleVisibleUntil[target])
        app.automation.receiveBLE(try XCTUnwrap(central.discoveries[0].manufacturerPayload),rssi:-45)
        let proof = try XCTUnwrap(app.conditionReadiness(target)); XCTAssertTrue(proof.ready)
        storage.failing = true
        await app.performAutomaticAction(.owned(app.owners[0],object),readiness:proof)
        XCTAssertEqual(central.connects,0); XCTAssertTrue(central.channel.writes.isEmpty)
        XCTAssertFalse(app.bleAutomationDisarmed.contains(target.id)); XCTAssertTrue(app.journal.isEmpty)
    }

    func testDurableJournalAndProofBeforeOneWriteAndFirstFireResult() async throws {
        let (storage, central, app, object, secret) = try fixture()
        let model = BLEOwnerControlModel(app: app, transport: central)
        central.channel.beforeWrite = {
            XCTAssertEqual(storage.state?.journal?.count, 1)
            XCTAssertEqual(storage.state?.owners?.first?.objects?.first?.bleProofs?.count, 1)
            XCTAssertTrue(storage.state?.bleAutomationDisarmed?.contains(ObjectReference.owned(server:"fixture.invalid",objectID:object.id).id) == true)
        }
        await model.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.channel.writes, [try BLECrypto.ownerFire(ownerSecret: secret, nonce: central.channel.nonce)])
        XCTAssertEqual(app.journal.first?.result, "Контроллер принял команду")
        XCTAssertTrue(central.channel.closed)
        XCTAssertFalse(model.busy)
        // A fresh application cannot reuse this consumed challenge.
        let restored = AppModel(storage: storage)
        XCTAssertTrue(restored.bleAutomationDisarmed.contains(ObjectReference.owned(server:"fixture.invalid",objectID:object.id).id))
        let again = BLEOwnerControlModel(app: restored, transport: central)
        await again.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.channel.writes.count, 1)
        XCTAssertEqual(restored.journal.count, 1)
    }
    func testSaveFailureAndUnauthenticatedDiscoveryNeverFire() async throws {
        let (storage, central, app, object, _) = try fixture()
        let model = BLEOwnerControlModel(app: app, transport: central)
        central.discoveries = [BLEDiscovery(id: UUID(), name: "Entrixy", rssi: -20, manufacturerPayload: Data(repeating: 0, count: 16))]
        await model.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.connects, 0); XCTAssertTrue(app.journal.isEmpty)
        let (_, validCentral, _, _, _) = try fixture()
        // Its secret is different, so even another valid controller is refused.
        central.discoveries = validCentral.discoveries
        await model.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.connects, 0)
        let (failing, valid, savedApp, target, _) = try fixture()
        failing.failing = true
        let blocked = BLEOwnerControlModel(app: savedApp, transport: valid)
        await blocked.execute(server: "fixture.invalid", objectID: target.id)
        XCTAssertTrue(valid.channel.writes.isEmpty); XCTAssertTrue(savedApp.journal.isEmpty)
        XCTAssertNil(failing.state?.owners?.first?.objects?.first?.bleProofs)
        _ = storage
    }
    func testLostWriteAndLegacyWriteAckRemainUnknownWithoutReplay() async throws {
        let (storage, central, app, object, _) = try fixture()
        central.channel.lostReply = true
        let model = BLEOwnerControlModel(app: app, transport: central)
        await model.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.channel.writes.count, 1)
        XCTAssertEqual(app.journal.first?.level, "warning")
        XCTAssertTrue(app.journal.first?.result.contains("неизвестен") == true)
        XCTAssertEqual(storage.state?.journal?.count, 1)
        let (_, legacy, otherApp, target, _) = try fixture()
        legacy.channel.hasResults = false
        let oldModel = BLEOwnerControlModel(app: otherApp, transport: legacy)
        await oldModel.execute(server: "fixture.invalid", objectID: target.id)
        XCTAssertEqual(legacy.channel.writes.count, 1)
        XCTAssertEqual(otherApp.journal.first?.level, "warning")
        XCTAssertTrue(otherApp.journal.first?.result.contains("не подтверждает") == true)
    }
    func testBackgroundDuringScanPreventsConnectAndJournal() async throws {
        let (_, central, app, object, _) = try fixture()
        let model = BLEOwnerControlModel(app: app, transport: central)
        central.beforeReadReturn = { model.suspend() }
        await model.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.connects, 0); XCTAssertTrue(app.journal.isEmpty)
    }
    func testOwnerDeliversSignedDecisionWithoutPhysicalActionAndOnlyResult40Confirms() async throws {
        let (storage, central, _, object, secret) = try fixture()
        var owner = storage.state!.owners![0]
        let record = try BLERevocation(deviceID: object.bleDeviceID!, guestID: 9, version: 100, revoked: true, ownerSecret: secret)
        owner.bleRevocations = [record]; storage.state!.owners = [owner]
        let app = AppModel(storage: storage)
        let control = BLEOwnerControlModel(app: app, transport: central)
        central.channel.beforeRevoke = {
            XCTAssertEqual(storage.state?.owners?.first?.bleRevocations?.first?.frame, record.frame)
            XCTAssertTrue(storage.state?.journal?.isEmpty ?? true)
        }
        await control.deliverDecisions(server: "fixture.invalid", deviceID: object.bleDeviceID!)
        XCTAssertEqual(central.channel.writes, [record.frame])
        XCTAssertEqual(app.owners[0].bleRevocations?.first?.applied, true)
        XCTAssertTrue(app.journal.isEmpty)
        let (staleStore, staleCentral, _, staleObject, staleSecret) = try fixture()
        let staleRecord = try BLERevocation(deviceID: staleObject.bleDeviceID!, guestID: 9, version: 100, revoked: true, ownerSecret: staleSecret)
        staleStore.state!.owners![0].bleRevocations = [staleRecord]
        let staleApp = AppModel(storage: staleStore)
        staleCentral.channel.revokeResult = 0x41
        let stale = BLEOwnerControlModel(app: staleApp, transport: staleCentral)
        await stale.deliverDecisions(server: "fixture.invalid", deviceID: staleObject.bleDeviceID!)
        XCTAssertEqual(staleApp.owners[0].bleRevocations?.first?.controllerResult, 0x41)
        XCTAssertEqual(staleApp.owners[0].bleRevocations?.first?.applied, false)
        XCTAssertTrue(staleApp.journal.isEmpty)
    }
    func testOwnerRefusesFireWhenRevocationReceiptCannotBeSaved() async throws {
        let (storage, central, _, object, secret) = try fixture()
        let record = try BLERevocation(deviceID: object.bleDeviceID!, guestID: 9, version: 100, revoked: true, ownerSecret: secret)
        storage.state!.owners![0].bleRevocations = [record]
        let app = AppModel(storage: storage)
        let model = BLEOwnerControlModel(app: app, transport: central)
        central.channel.beforeRevoke = { storage.failing = true }
        await model.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.channel.writes, [record.frame])
        XCTAssertTrue(app.journal.isEmpty)
        XCTAssertNil(storage.state?.owners?.first?.bleRevocations?.first?.controllerResult)
    }

    func testRestoredOwnerAuthenticationCannotBeSkippedByDirectBLEControl() async throws {
        let (storage, central, _, object, _) = try fixture()
        storage.state!.owners![0].objects![0].localPolicy = Data(#"{"auth_on":true,"auth":"pin"}"#.utf8)
        let app = AppModel(storage: storage)
        let control = BLEOwnerControlModel(app: app, transport: central)
        await control.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.connects, 0)
        XCTAssertTrue(central.channel.writes.isEmpty)
        XCTAssertTrue(app.journal.isEmpty)
        XCTAssertNil(app.errorMessage)
        XCTAssertNotNil(app.ownerActionRejections[object.id])
        XCTAssertEqual(try OwnerManualPolicy(storage.state!.owners![0].objects![0].localPolicy).authentication, "pin")
    }

    func testPairedOwnerBLEWorksBeforeServerAcknowledgementWithoutRegisteringOrRetryingMetadata() async throws {
        let (storage, central, _, object, _) = try fixture()
        storage.state!.owners![0].credentials = nil
        storage.state!.owners![0].objects![0].numberID = nil
        storage.state!.owners![0].objects![0].pending = .create
        storage.state!.owners![0].objects![0].sent = true
        storage.state!.owners![0].objects![0].available = false
        let app = AppModel(storage: storage)
        let control = BLEOwnerControlModel(app: app, transport: central)
        XCTAssertTrue(app.owners[0].objects![0].ownerCardAvailable)
        XCTAssertNotNil(app.ownerActionIntent(server:"fixture.invalid",objectID:object.id),"A paired offline owner must also be reachable from the real control-card action path")
        await control.execute(server: "fixture.invalid", objectID: object.id)
        XCTAssertEqual(central.channel.writes.count, 1)
        XCTAssertEqual(app.journal.first?.result, "Контроллер принял команду")
        XCTAssertNil(storage.state?.owners?.first?.credentials)
        XCTAssertNil(storage.state?.owners?.first?.objects?.first?.numberID)
        XCTAssertEqual(storage.state?.owners?.first?.objects?.first?.pending, .create)
        XCTAssertEqual(storage.state?.owners?.first?.objects?.first?.sent, true)
    }

}
