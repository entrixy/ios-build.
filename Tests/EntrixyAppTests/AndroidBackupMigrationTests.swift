import XCTest
import EntrixyCore
@testable import Entrixy

private final class AndroidImportStorage: StateStorage {
    var state: SavedState?
    var failing = false
    init(identity: Data) { state = SavedState(identity:identity,guests:[]) }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { if failing { throw KeychainStore.Failure(status:-1) }; self.state = state }
}
private struct NoAndroidOwnerAPI: OwnerTransport {
    func register(server: String,accessCode: String) async throws -> OwnerCredentials { throw BackupFailure.noAccess }
    func sync(server: String,credentials: OwnerCredentials,fingerprint: String) async throws -> Data { throw BackupFailure.noAccess }
}
private final class AndroidIncomingMover: GuestMigrationTransport {
    var moves: [(GuestSigningIdentity,String,String)] = []
    var recoveries = 0
    var failRecoveryOnce = false
    var bundleAvailable = true
    var beforeMove: (() -> Void)?
    let key = Data(repeating:12,count:32)
    func move(invite: GuestInvite,oldFingerprint: String,newFingerprint: String) async throws { XCTFail("Android uses the actual signing identity"); throw BackupFailure.noAccess }
    func move(identity: GuestSigningIdentity,oldFingerprint: String,newFingerprint: String) async throws { beforeMove?(); moves.append((identity,oldFingerprint,newFingerprint)) }
    func recover(identity: GuestSigningIdentity,bundleKey: Data?,recipient: BundleKeySeal.Recipient?,fingerprint: String) async throws -> GuestInvite? {
        recoveries += 1
        if failRecoveryOnce { failRecoveryOnce = false; throw URLError(.networkConnectionLost) }
        if !bundleAvailable { return nil }
        XCTAssertNotNil(recipient)
        return try identity.invitation(bundleKey:key)
    }
}

@MainActor final class AndroidBackupMigrationTests: XCTestCase {
    private let target = Data(repeating:31,count:32)
    private func document() throws -> AndroidBackupDocument {
        let master = Data(repeating:7,count:32), recipient = BundleKeySeal.makeRecipient()
        let values: [String:String] = ["backup_src_seed":String(repeating:"ab",count:32),"e2ee_master_key":GuestCrypto.base64URL(master),"owner_self_label":"Хозяин",
            "guest_keys":#"[{"id":3,"host":"owner.invalid","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX","label":"Ключ от ворот"}]"#,
            "dlg_pub_3":recipient.publicKey,"dlg_priv_3":try GuestCrypto.encrypt(key:master,plaintext:Data(recipient.privateKey.utf8)),"future_private_setting":"keep this untouched",
            "e2ee_in_tpl_3_7":#"{"auth_on":true,"auth":"pin"}"#,"e2ee_in_tplo_3_7":"{}",
            "blocked_wifi":#"[{"s":"My home"}]"#,"blocked_wifi_g_3":#"[{"s":"Owner home"}]"#]
        let entries = values.mapValues { ["t":"s","v":$0] }
        return try AndroidBackupDocument(JSONSerialization.data(withJSONObject:["app":"entrixy","ver":1,"created":1800000000,"device":"Public fixture","count":entries.count,"entries":entries]))
    }
    private func inspect(_ document: AndroidBackupDocument,manager: BackupManager) async throws {
        let encrypted = try BackupEnvelope.seal(document.original,password:"test-password")
        try await manager.inspect(encrypted,password:"test-password")
    }
    func testAndroidPlanIsProtectedBeforeMoveAndRecoveryResumesWithoutMovingAgain() async throws {
        let source = try document(), storage = AndroidImportStorage(identity:target), mover = AndroidIncomingMover()
        let app = AppModel(storage:storage,ownerAPI:NoAndroidOwnerAPI()); defer { app.suspend() }
        let manager = BackupManager(app:app,guestMover:mover,refreshAfterRestore:false)
        try await inspect(source,manager:manager)
        XCTAssertEqual(manager.preview?.androidGuests?.count,1); XCTAssertTrue(mover.moves.isEmpty)
        storage.failing = true; await manager.restore(); XCTAssertTrue(mover.moves.isEmpty)
        storage.failing = false; mover.failRecoveryOnce = true
        mover.beforeMove = { XCTAssertEqual(storage.state?.pendingRestore?.payload.androidArchives?.first?.original,source.original) }
        await manager.restore()
        XCTAssertEqual(mover.moves.count,1); XCTAssertEqual(storage.state?.pendingRestore?.movedAndroidGuests?.count,1)
        XCTAssertEqual(mover.moves[0].1,try MigrationFingerprint.android(seed:String(repeating:"ab",count:32),server:"owner.invalid"))
        XCTAssertEqual(mover.moves[0].2,try MigrationFingerprint.ios(identity:target,server:"owner.invalid"))
        let restarted = AppModel(storage:storage,ownerAPI:NoAndroidOwnerAPI()); defer { restarted.suspend() }
        let resumed = BackupManager(app:restarted,guestMover:mover,refreshAfterRestore:false)
        await resumed.restore()
        XCTAssertEqual(mover.moves.count,1); XCTAssertNil(storage.state?.pendingRestore)
        XCTAssertEqual(restarted.guests.first?.invite.userKey,mover.moves[0].0.userKey)
        XCTAssertEqual(restarted.guests.first?.androidAutomation?["7"]?.local.authMode,"pin")
        XCTAssertEqual(restarted.guests.first?.privacyNetworks?.map(\.ssid),["Owner home"])
        XCTAssertEqual(restarted.networkPrivacy.own.map(\.ssid),["My home"])
        XCTAssertFalse(restarted.networkPrivacy.cellularAuthorized)
        XCTAssertEqual(storage.state?.identity,target); XCTAssertEqual(storage.state?.androidArchives?.first?.original,source.original)
        XCTAssertEqual(restarted.ownerGuestDefaults.ownerName,"Хозяин"); XCTAssertTrue(restarted.journal.isEmpty)
        let payload = IOSBackupPayload(state:storage.state!); try payload.validate()
        XCTAssertTrue((payload.androidGuests ?? []).isEmpty)
        XCTAssertEqual(payload.guests.count,1); XCTAssertEqual(payload.androidArchives?.first?.original,source.original)
    }
    func testWaitingRecipientRemainsUsableAndNextIOSBackupUsesCurrentDeviceFingerprint() async throws {
        let source = try document(), storage = AndroidImportStorage(identity:target), mover = AndroidIncomingMover()
        mover.bundleAvailable = false
        let app = AppModel(storage:storage,ownerAPI:NoAndroidOwnerAPI()); defer { app.suspend() }
        let manager = BackupManager(app:app,guestMover:mover,refreshAfterRestore:false)
        try await inspect(source,manager:manager); await manager.restore()
        XCTAssertNil(storage.state?.pendingRestore); XCTAssertTrue(app.canManageGuestAccess)
        XCTAssertTrue(app.guests.isEmpty); XCTAssertEqual(app.androidPendingGuests.count,1)
        XCTAssertEqual(app.androidPendingGuests[0].incomingAutomation?["7"]?.local.authMode,"pin")
        XCTAssertEqual(app.androidPendingGuests[0].privacyNetworks?.map(\.ssid),["Owner home"])
        let recipient = app.androidPendingGuests[0].recipient
        let payload = IOSBackupPayload(state:storage.state!); try payload.validate()
        XCTAssertEqual(payload.androidGuests?.first?.oldFingerprint,try MigrationFingerprint.ios(identity:target,server:"owner.invalid"))
        XCTAssertEqual(payload.androidGuests?.first?.recipient?.privateKey,recipient?.privateKey)
        mover.bundleAvailable = true; storage.failing = true
        await manager.recoverImportedGuest(app.androidPendingGuests[0].id)
        XCTAssertEqual(app.androidPendingGuests.first?.recipient?.privateKey,recipient?.privateKey); XCTAssertTrue(app.guests.isEmpty)
        storage.failing = false
        await manager.recoverImportedGuest(app.androidPendingGuests[0].id)
        XCTAssertEqual(app.guests.count,1); XCTAssertTrue(app.androidPendingGuests.isEmpty)
        XCTAssertEqual(app.guests[0].androidAutomation?["7"]?.local.authMode,"pin")
        XCTAssertEqual(app.guests[0].privacyNetworks?.map(\.ssid),["Owner home"])
        XCTAssertEqual(app.guests[0].requiresBLEExitOnRestore,true)
        XCTAssertEqual(storage.state?.identity,target); XCTAssertEqual(mover.moves.count,1)
    }
}
