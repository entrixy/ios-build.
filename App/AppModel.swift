import Foundation
import Combine
import EntrixyCore

struct ActionTapRejection {
    let id = UUID()
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var actionRejections: [String: ActionTapRejection] = [:]

    @Published private(set) var owners: [OwnerAccount] = []
    @Published private(set) var ownerBusy = false
    @Published private(set) var ownerSnapshots: [String: OwnerSnapshot] = [:]
    @Published private(set) var ownerMessages: [String: String] = [:]
    @Published private(set) var ownerObjectMessages: [UUID: String] = [:]
    private let ownerAPI: OwnerTransport
    @Published private(set) var ownerKeyMessages: [UUID: String] = [:]
    @Published private(set) var ownerDelegationMessages: [UUID: String] = [:]
    @Published private(set) var unverifiedOwnerDelegations: [String: Int] = [:]
    private var unsavedOwnerKeys: [UUID: OwnerIssuedKey] = [:]
    private var unsavedOwnerObjects: [UUID: OwnerObject] = [:]
    private var editingOwnerKeys = Set<UUID>()
    private var ownerBundleRetryAfter: [String: Date] = [:]
    private var ownerBundleRetryAttempts: [String: Int] = [:]
    private var ownerSettingsTask: Task<Void, Never>?
    private var ownerSettingsTaskGeneration: UUID?
    private var unsavedOwnerCredentials: [String: OwnerCredentials] = [:]
    @Published private(set) var guests: [SavedGuest] = []
    @Published var objectRemovalTarget: ObjectReference?
    @Published var objectAvatarTarget: ObjectReference?
    @Published var ownerGuestRequestPending = false
    lazy var automationSensors = AutomationSensors()
    @Published private(set) var objectPreferences = ObjectCatalogPreferences()
    @Published private(set) var bleVisibleUntil: [ObjectReference: TimeInterval] = [:]
    @Published private(set) var busy = false
    @Published private(set) var storageReady = false
    @Published private(set) var journal: [JournalEntry] = []
    @Published private(set) var connections: [String: GuestConnection] = [:]
    @Published private(set) var avatars: [String: Data] = [:]
    @Published private(set) var actionMessages: [String: String] = [:]
    private var actionLinks: [String: ActionLink] = [:]
    private let avatarCache = AvatarCache()
    @Published var errorMessage: String?
    private var identity = Data()
    private var pendingRestore: BackupRestorePlan?
    lazy var backups = BackupManager(app: self)
    lazy var delegationInbox = DelegationInbox(app: self)
    lazy var passManager = PassManager(app: self)
    private lazy var bleTransport = CoreBluetoothTransport()
    lazy var blePairing = BLEPairingModel(app: self, transport: bleTransport)
    lazy var bleGuestControl = BLEGuestControlModel(app: self, transport: bleTransport)
    private var bleAuthorizedIntent: UUID?
    lazy var bleControl = BLEOwnerControlModel(app: self, transport: bleTransport)
    lazy var messages = MessageManager(app: self)
    @Published private(set) var incomingMessages: [SavedMessage] = []
    @Published private(set) var outgoingMessages: [OutgoingMessage] = []
    @Published private(set) var passedAccess: [PassedAccess] = []
    @Published private(set) var receivedDelegations: [ReceivedDelegation] = []
    var canManageGuestAccess: Bool { storageReady && foreground && !appLocked && pendingRestore == nil }
    @Published private(set) var delegations: [DelegationRedemption] = []
    private var usedOwnerPresses: [String: Date] = [:]
    private var delegatedJournalLedger = DelegatedJournalLedger()
    private var entryLockPolicy = AppEntryLockPolicy()
    @Published private(set) var appLockEnabled = false
    @Published private(set) var appEntryBiometricEnabled = false
    @Published private(set) var appLocked = false
    lazy var ownerControl = OwnerControlModel(app: self)
    private var actionCode: LocalActionCode?
    private var authenticationBusy = false
    private var authorizedIntent: UUID?
    private var activeOwnerAction: OwnerActionIntent?
    @Published private(set) var ownerActionRejections: [UUID: ActionTapRejection] = [:]
    var hasActionCode: Bool { actionCode != nil }
    private let storage: StateStorage
    private let biometricService: String
    private let api = GuestAPI()
    private var watchers: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var foreground = true
    private var resumeRequested = false
    private var syncFailure: String?

    init(storage: StateStorage = KeychainStore(), ownerAPI: OwnerTransport = OwnerAPI()) {
        self.storage = storage
        biometricService = (storage as? KeychainStore)?.biometricService ?? "com.entrixy.ios.fixture-biometry." + UUID().uuidString
        self.ownerAPI = ownerAPI
        var startupStatus: Int32 = 0
        do {
            let state: SavedState
            if let saved = try storage.load() { state = saved }
            else {
                #if DEBUG && targetEnvironment(simulator)
                let bootstrap = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("preview-bootstrap.json")
                if FileManager.default.fileExists(atPath: bootstrap.path) {
                    state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: bootstrap))
                    guard state.identity.count == 32 else { throw KeychainStore.Failure(status: -1) }
                } else { state = SavedState(identity: GuestCrypto.randomBytes(count: 32), guests: []) }
                #else
                state = SavedState(identity: GuestCrypto.randomBytes(count: 32), guests: [])
                #endif
                try storage.save(state)
                #if DEBUG && targetEnvironment(simulator)
                try? FileManager.default.removeItem(at: bootstrap)
                #endif
            }
            delegatedJournalLedger = state.delegatedJournalLedger ?? DelegatedJournalLedger()
            try delegatedJournalLedger.validate()
            owners = state.owners ?? []
            let preferences = state.objectPreferences ?? ObjectCatalogPreferences()
            try preferences.validate()
            objectPreferences = preferences
            usedOwnerPresses = state.usedOwnerPresses ?? [:]
            pendingRestore = state.pendingRestore
            delegations = state.delegations ?? []
            passedAccess = state.passedAccess ?? []
            receivedDelegations = state.receivedDelegations ?? []
            incomingMessages = state.incomingMessages ?? []
            outgoingMessages = state.outgoingMessages ?? []
            actionCode = state.actionCode
            appLockEnabled = state.appLockEnabled ?? false
            appEntryBiometricEnabled = state.appEntryBiometricEnabled ?? false
            appLocked = appLockEnabled
            guard !(appLockEnabled || appEntryBiometricEnabled) || actionCode != nil else { throw KeychainStore.Failure(status: -1) }
            appLocked = entryLockPolicy.requiresUnlock(enabled: appLockEnabled, hasCode: actionCode != nil, now: ProcessInfo.processInfo.systemUptime)
            identity = state.identity
            guests = state.guests
            journal = (state.journal ?? []).filter(\.isAction)
            storageReady = true
        } catch {
            startupStatus = (error as? KeychainStore.Failure)?.status ?? -1
            errorMessage = "Не удалось прочитать защищённое хранилище. Повторно откройте приложение после разблокировки iPhone."
        }
        writePreviewStatus(status: startupStatus)
    }

    private func writePreviewStatus(status: Int32 = 0) {
        #if DEBUG && targetEnvironment(simulator)
        if let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let diagnostic: [String: Any] = ["ready": storageReady, "status": status,
                "busy": busy, "objects": guests.flatMap(\.objects).count, "failed": errorMessage != nil,
                "journal_count": journal.count, "live_connections": connections.values.filter { $0 == .connected }.count,
                "sync_failure": syncFailure ?? "none"]
            if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic) {
                try? bytes.write(to: cache.appendingPathComponent("preview-status.json"), options: .atomic)
            }
        }
        #endif
    }

    private func save(_ updated: [SavedGuest], preferences: ObjectCatalogPreferences? = nil) throws {
        let preferences = preferences ?? objectPreferences
        try preferences.validate()
        try storage.save(SavedState(identity: identity, guests: updated, journal: journal, actionCode: actionCode, owners: owners, usedOwnerPresses: usedOwnerPresses, pendingRestore: pendingRestore, delegations: delegations, passedAccess: passedAccess, receivedDelegations: receivedDelegations, incomingMessages: incomingMessages, outgoingMessages: outgoingMessages, delegatedJournalLedger: delegatedJournalLedger, appLockEnabled: appLockEnabled, appEntryBiometricEnabled: appEntryBiometricEnabled, objectPreferences: preferences))
        guests = updated
        if objectPreferences != preferences { objectPreferences = preferences }
    }

    @discardableResult func saveObjectPreferences(_ preferences: ObjectCatalogPreferences) -> Bool {
        guard canManageGuestAccess, !busy, !ownerBusy else { return false }
        do { try save(guests, preferences: preferences); return true }
        catch { errorMessage = "Не удалось сохранить настройки объекта. Прежние настройки сохранены."; return false }
    }

    func makeOwnerLive(_ owner: OwnerAccount) throws -> OwnerLiveTransport {
        guard storageReady, foreground, let credentials = owner.credentials else { throw GuestCrypto.Failure.invalidEnvelope }
        return try ownerAPI.live(server: owner.server, credentials: credentials, fingerprint: GuestCrypto.hash(identity + Data(owner.server.utf8)))
    }

    func consumeOwnerPress(_ key: String) throws {
        guard usedOwnerPresses[key] == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        let previous = usedOwnerPresses
        usedOwnerPresses = usedOwnerPresses.filter { Date().timeIntervalSince($0.value) < 600 }
        guard usedOwnerPresses.count < 2048 else { usedOwnerPresses = previous; throw GuestCrypto.Failure.invalidEnvelope }
        usedOwnerPresses[key] = Date()
        do { try save(guests) } catch { usedOwnerPresses = previous; throw error }
    }

    private func mergedIncoming(_ source: [SavedMessage]) throws -> [SavedMessage] {
        var rows = incomingMessages
        for item in source {
            if let i = rows.firstIndex(where: { $0.id == item.id }) {
                if rows[i].readAt == nil { rows[i].readAt = item.readAt }
                rows[i].deliveryAcknowledged = rows[i].deliveryAcknowledged || item.deliveryAcknowledged
                rows[i].readAcknowledged = rows[i].readAcknowledged || item.readAcknowledged
            } else { rows.append(item) }
        }
        rows.sort { $0.receivedAt > $1.receivedAt }
        while rows.count > 200 {
            guard let i = rows.lastIndex(where: { $0.readAt != nil && $0.readAcknowledged }) else { throw BackupFailure.conflictingAccess }
            rows.remove(at: i)
        }
        return rows
    }
    func saveMessages(incoming: [SavedMessage]? = nil, outgoing: [OutgoingMessage]? = nil) throws {
        guard storageReady else { throw BackupFailure.busy }
        let oldIncoming = incomingMessages, oldOutgoing = outgoingMessages
        if let incoming { incomingMessages = incoming }
        if let outgoing { outgoingMessages = outgoing }
        do { try save(guests) } catch { incomingMessages = oldIncoming; outgoingMessages = oldOutgoing; throw error }
    }
    func ownerMessageMaterial(server: String, keyID: UUID) throws -> (serverKeyID: Int, bundleKey: Data) {
        guard storageReady, let owner = owners.first(where: { $0.server == server }), let key = owner.issuedKeys?.first(where: { $0.id == keyID }),
              let id = key.keyID, key.pending == nil, [.active, .paused, .restricted].contains(key.state) else { throw BackupFailure.noAccess }
        return (id, try key.secrets(masterKey: owner.masterKey).bundleKey)
    }
    func sendOwnerMessage(server: String, keyID: UUID, cipher: String) async throws {
        let material = try ownerMessageMaterial(server: server, keyID: keyID)
        guard let credentials = owners.first(where: { $0.server == server })?.credentials else { throw BackupFailure.noAccess }
        let body = try JSONSerialization.data(withJSONObject: ["user_key_id": material.serverKeyID, "cipher": cipher], options: .sortedKeys)
        let response = try await ownerAPI.mutate(server: server, credentials: credentials,
            fingerprint: backupFingerprint(server: server), operation: .messageSend, body: body)
        guard let row = try JSONSerialization.jsonObject(with: response) as? [String: Any], (row["ok"] as? NSNumber)?.boolValue == true else { throw BackupFailure.invalidPayload }
    }

    func savePassedAccess(_ record: PassedAccess) throws {
        guard storageReady, pendingRestore == nil else { throw BackupFailure.busy }
        try record.validate()
        let previous = passedAccess
        if let index = passedAccess.firstIndex(where: { $0.id == record.id }) { passedAccess[index] = record }
        else {
            guard passedAccess.count < 500,
                  !passedAccess.contains(where: { $0.group == nil && $0.parts.contains(where: { $0.sent }) }) else { throw BackupFailure.busy }
            passedAccess.append(record)
        }
        do { try save(guests) } catch { passedAccess = previous; throw error }
    }

    func reserveDelegation(_ pending: DelegationRedemption) throws {
        guard storageReady, !busy, !ownerBusy, pendingRestore == nil, delegations.count < 100,
              !delegations.contains(where: { $0.id == pending.id }) else { throw BackupFailure.busy }
        let previous = delegations
        delegations.append(pending)
        do { try save(guests) } catch { delegations = previous; throw error }
    }
    func removePendingDelegation(_ id: String) {
        guard storageReady, !busy, !ownerBusy, pendingRestore == nil else { return }
        let previous = delegations
        delegations.removeAll { $0.id == id }
        do { try save(guests) }
        catch { delegations = previous; errorMessage = "Не удалось сохранить удаление. Данные получателя сохранены." }
    }
    func markDelegationSent(_ id: String) throws {
        guard storageReady, !busy, !ownerBusy, pendingRestore == nil,
              let i = delegations.firstIndex(where: { $0.id == id }), !delegations[i].sent else { throw BackupFailure.busy }
        delegations[i].sent = true
        do { try save(guests) } catch { delegations[i].sent = false; throw error }
    }
    func installDelegatedInvite(_ invite: GuestInvite, pendingID: String, code: String) throws {
        guard storageReady, !busy, !ownerBusy, pendingRestore == nil,
              let i = delegations.firstIndex(where: { $0.id == pendingID }),
              delegations[i].sent, delegations[i].link.server == invite.server,
              delegations[i].parts.contains(where: { $0.code == code && $0.userKey == invite.userKey }) else { throw BackupFailure.busy }
        if let current = guests.first(where: { $0.id == invite.id }), current.invite != invite { throw BackupFailure.conflictingAccess }
        let previous = delegations, previousReceived = receivedDelegations
        if !delegations[i].completedCodes.contains(code) { delegations[i].completedCodes.append(code) }
        do {
            let receipt = try ReceivedDelegation(pending: delegations[i])
            if let offset = receivedDelegations.firstIndex(where: { $0.id == receipt.id }) { try receivedDelegations[offset].merge(receipt) }
            else { receivedDelegations.append(receipt) }
        } catch { delegations = previous; receivedDelegations = previousReceived; throw error }
        if delegations[i].completedCodes.count == delegations[i].parts.count { delegations.remove(at: i) }
        var updated = guests
        if !updated.contains(where: { $0.id == invite.id }) { updated.append(SavedGuest(invite: invite)) }
        do { try save(updated) } catch { delegations = previous; receivedDelegations = previousReceived; throw error }
    }

    func backupState() throws -> SavedState {
        guard delegations.isEmpty else { throw BackupFailure.pendingAccess }
        guard storageReady, let state = try storage.load(), pendingRestore == nil else { throw BackupFailure.busy }
        return state
    }
    func backupPlan() -> BackupRestorePlan? { pendingRestore }
    func backupFingerprint(server: String) throws -> String { try MigrationFingerprint.ios(identity: identity, server: server) }
    func validateRestoreConflicts(_ payload: IOSBackupPayload) throws {
        guard storageReady else { throw BackupFailure.invalidPayload }
        try payload.validate()
        _ = try mergedIncoming(payload.incomingMessages ?? [])
        for item in payload.outgoingMessages ?? [] {
            if let existing = outgoingMessages.first(where: { $0.id == item.id }), existing.cipher != item.cipher || existing.target != item.target { throw BackupFailure.conflictingAccess }
        }
        for source in payload.owners {
            if let current = owners.first(where: { $0.server == source.server }) {
                do { _ = try current.mergingBackup(source) } catch { throw BackupFailure.conflictingAccess }
            }
        }
        for source in payload.guests {
            if let current = guests.first(where: { $0.id == source.id }), current.invite != source.invite { throw BackupFailure.conflictingAccess }
        }
        for source in payload.receivedDelegations ?? [] {
            if var current = receivedDelegations.first(where: { $0.id == source.id }) {
                do { try current.merge(source) } catch { throw BackupFailure.conflictingAccess }
            }
        }
        for source in payload.passedAccess ?? [] {
            if let current = passedAccess.first(where: { $0.id == source.id || (source.group != nil && $0.server == source.server && $0.group == source.group) }),
               current.secret != source.secret || current.server != source.server { throw BackupFailure.conflictingAccess }
        }
    }
    func saveBackupPlan(_ plan: BackupRestorePlan?) throws {
        let previous = pendingRestore
        pendingRestore = plan
        do { try save(guests) } catch { pendingRestore = previous; throw error }
    }
    func beginBackupRestore() throws {
        guard storageReady, !ownerBusy, !busy else { throw BackupFailure.busy }
        ownerBusy = true; busy = true
        let wasForeground = foreground
        ownerControl.suspend()
        delegationInbox.suspend()
        pauseGuestSessions()
        foreground = wasForeground
    }
    func endBackupRestore(refresh: Bool = true) {
        ownerBusy = false; busy = false
        guard refresh, foreground else { return }
        ownerControl.resume()
        delegationInbox.resume()
        Task { [weak self] in
            await self?.refreshOwners()
            await self?.refresh()
        }
    }
    func claimBackupOwner(_ owner: OwnerAccount, dryRun: Bool) async throws {
        guard let credentials = owner.credentials else { return }
        let body = try JSONSerialization.data(withJSONObject: dryRun ? ["dry_run": 1] : [:])
        let bytes = try await ownerAPI.mutate(server: owner.server, credentials: credentials,
            fingerprint: backupFingerprint(server: owner.server), operation: .hostClaim, body: body)
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (json["ok"] as? NSNumber)?.boolValue == true else { throw BackupFailure.invalidPayload }
    }
    func activateBackupOwner(_ owner: OwnerAccount, plan: BackupRestorePlan) throws {
        var updated = owners
        let existingIndex = updated.firstIndex(where: { $0.server == owner.server })
        do {
            var imported = try existingIndex.map { try updated[$0].mergingBackup(owner) } ?? owner
            imported.lastSynced = nil
            if var objects = imported.objects {
                for i in objects.indices { objects[i].available = false }
                imported.objects = objects
            }
            if var keys = imported.issuedKeys {
                for i in keys.indices where keys[i].keyID != nil && keys[i].state != .revoked { keys[i].state = .unavailable }
                imported.issuedKeys = keys
            }
            if var keys = imported.delegatedKeys {
                for i in keys.indices where keys[i].state != .revoked { keys[i].state = .unavailable }
                imported.delegatedKeys = keys
            }
            if let existingIndex { updated[existingIndex] = imported } else { updated.append(imported) }
        }
        let previous = pendingRestore
        pendingRestore = plan
        do { try saveOwners(updated) } catch { pendingRestore = previous; throw error }
    }
    func activateBackupGuest(_ guest: SavedGuest, plan: BackupRestorePlan) throws {
        var updated = guests
        if !updated.contains(where: { $0.id == guest.id }) {
            var imported = guest
            imported.objects = []; imported.checkedAt = nil
            updated.append(imported)
        }
        let previous = pendingRestore
        pendingRestore = plan
        do { try save(updated) } catch { pendingRestore = previous; throw error }
    }
    func finishBackupRestore(_ plan: BackupRestorePlan) throws {
        let previousPlan = pendingRestore, previousJournal = journal, previousPresses = usedOwnerPresses
        let previousPassed = passedAccess
        let previousReceived = receivedDelegations
        let previousIncoming = incomingMessages, previousOutgoing = outgoingMessages
        let previousLedger = delegatedJournalLedger
        let restoredPreferences = try objectPreferences.merging(plan.payload.objectPreferences)
        let restoredIncoming = try mergedIncoming(plan.payload.incomingMessages ?? [])
        let existing = Set(journal.map(\.id))
        journal += plan.payload.journal.filter { $0.isAction && !existing.contains($0.id) }
        journal.sort { $0.date > $1.date }; journal = Array(journal.prefix(500))
        for (key, date) in plan.payload.usedOwnerPresses where Date().timeIntervalSince(date) < 600 {
            usedOwnerPresses[key] = date
        }
        usedOwnerPresses = usedOwnerPresses.filter { Date().timeIntervalSince($0.value) < 600 }
        guard usedOwnerPresses.count <= 2048 else {
            journal = previousJournal; usedOwnerPresses = previousPresses
            throw BackupFailure.busy
        }
        for source in plan.payload.passedAccess ?? [] {
            if !passedAccess.contains(where: { $0.id == source.id || (source.group != nil && $0.server == source.server && $0.group == source.group) }) { passedAccess.append(source) }
        }
        do {
            for source in plan.payload.receivedDelegations ?? [] {
                if let i = receivedDelegations.firstIndex(where: { $0.id == source.id }) { try receivedDelegations[i].merge(source) }
                else { receivedDelegations.append(source) }
            }
            incomingMessages = restoredIncoming
            for row in plan.payload.outgoingMessages ?? [] where !outgoingMessages.contains(where: { $0.id == row.id }) { outgoingMessages.append(row) }
            outgoingMessages.sort { $0.created > $1.created }; outgoingMessages = Array(outgoingMessages.prefix(100))
            if let ledger = plan.payload.delegatedJournalLedger { try delegatedJournalLedger.merge(ledger) }
            pendingRestore = nil
            try save(guests, preferences: restoredPreferences)
        } catch {
            pendingRestore = previousPlan; journal = previousJournal; usedOwnerPresses = previousPresses
            passedAccess = previousPassed; receivedDelegations = previousReceived
            incomingMessages = previousIncoming; outgoingMessages = previousOutgoing
            delegatedJournalLedger = previousLedger; throw error
        }
    }

    private func saveOwners(_ updated: [OwnerAccount]) throws {
        try storage.save(SavedState(identity: identity, guests: guests, journal: journal, actionCode: actionCode, owners: updated, usedOwnerPresses: usedOwnerPresses, pendingRestore: pendingRestore, delegations: delegations, passedAccess: passedAccess, receivedDelegations: receivedDelegations, incomingMessages: incomingMessages, outgoingMessages: outgoingMessages, delegatedJournalLedger: delegatedJournalLedger, appLockEnabled: appLockEnabled, appEntryBiometricEnabled: appEntryBiometricEnabled, objectPreferences: objectPreferences))
        owners = updated
        scheduleOwnerSettingsRefresh()
    }

    private func updateGuestMaterial(_ guest: inout SavedGuest, objects: [GuestObject], bundle: Data, snapshot: Data) throws {
        guard let contents = try JSONSerialization.jsonObject(with: bundle) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        let templates = contents["templates"] as? [String: [String: Any]] ?? [:]
        let ble = contents["ble"] as? [[String: Any]] ?? []
        guard contents["templates"] == nil || contents["templates"] is [String: [String: Any]],
              contents["ble"] == nil || contents["ble"] is [[String: Any]],
              contents["streams"] == nil || contents["streams"] is [Int],
              contents["cams"] == nil || contents["cams"] is [String: [String: Any]] else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        var rules: [String: IncomingAutomationConfiguration] = [:]
        var cameras: [String: ObjectCameraConfiguration] = [:]
        let streamIDs = Set(contents["streams"] as? [Int] ?? [])
        let cameraRows = contents["cams"] as? [String: [String: Any]] ?? [:]
        for object in objects {
            let raw = object.kind == "ble" ? (ble.first { ($0["id"] as? Int) == object.numberID }?["tpl"] as? [String: Any] ?? [:]) : (templates[String(object.numberID)] ?? [:])
            let fresh = try AutomationTemplate(data: JSONSerialization.data(withJSONObject: raw))
            if var previous = guest.automation?[object.id] { previous.receive(fresh); rules[object.id] = previous }
            else { rules[object.id] = IncomingAutomationConfiguration(owner: fresh) }
            if object.kind != "ble", streamIDs.contains(object.numberID), let row = cameraRows[String(object.numberID)] {
                cameras[object.id] = try ObjectCameraConfiguration(wire: row)
            }
        }
        guest.automation = rules; guest.cameras = cameras
        try updateBLECache(&guest, bundle: bundle, snapshot: snapshot)
    }

    private func updateBLECache(_ guest: inout SavedGuest, bundle: Data, snapshot: Data) throws {
        guard let contents = try JSONSerialization.jsonObject(with: bundle) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        guard let rows = contents["ble"] as? [[String: Any]], !rows.isEmpty else { guest.bleCache = nil; return }
        let epoch = UInt64(max(0, Date().timeIntervalSince1970))
        if var cache = guest.bleCache {
            try cache.refresh(bundle: bundle, snapshot: snapshot, key: guest.invite.bundleKey, epoch: epoch)
            guest.bleCache = cache
        } else { guest.bleCache = try GuestBLECache(bundle: bundle, snapshot: snapshot, key: guest.invite.bundleKey, epoch: epoch) }
    }
    func guestBLEMaterial(_ intent: ActionIntent) throws -> BLEGuestGrant {
        guard objectIsVisible(.received(guestID: intent.guestID, objectID: intent.object.id)),
              canManageGuestAccess, !busy, let guest = guests.first(where: { $0.id == intent.guestID }),
              !guest.paused, guest.objects.contains(intent.object), let cache = guest.bleCache,
              cache.revision == intent.revision else { throw BLETransportFailure.cancelled }
        let material = try cache.open(key: guest.invite.bundleKey)
        let decoded = try GuestActionPolicy.decodeBLE(bundle: material.bundle, numberID: intent.object.numberID,
            epoch: max(cache.maximumEpoch, UInt64(max(0, Date().timeIntervalSince1970))), overrides: guest.automation?[intent.object.id])
        guard decoded.policy.blockedReason == nil, decoded.policy.template == intent.policy.template else { throw BLETransportFailure.unsupported }
        if let snapshot = try JSONSerialization.jsonObject(with: material.snapshot) as? [String: Any],
           let row = (snapshot["numbers"] as? [[String: Any]])?.first(where: { ($0["id"] as? Int) == intent.object.numberID }),
           ["time_from", "time_to"].contains(where: { (row[$0] as? String).map { !$0.isEmpty } == true }) { throw BLETransportFailure.unsupported }
        return decoded.grant
    }
    func receiveBLERevocations(_ data: Data, guestID: String) throws {
        guard storageReady, let i = guests.firstIndex(where: { $0.id == guestID }), var cache = guests[i].bleCache else { return }
        let material = try cache.open(key: guests[i].invite.bundleKey)
        guard let bundle = try JSONSerialization.jsonObject(with: material.bundle) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        let dids = Set(try (bundle["ble"] as? [[String: Any]] ?? []).map { try BLEGuestGrant(row: $0).deviceID })
        let records = try BLERevocation.decode(data).filter { dids.contains($0.deviceID) }
        try cache.mergeRevocations(records)
        var updated = guests; updated[i].bleCache = cache; try save(updated)
    }
    func guestBLERevocations(_ intent: ActionIntent) throws -> [BLERevocation] {
        _ = try guestBLEMaterial(intent)
        return (guests.first(where: { $0.id == intent.guestID })?.bleCache?.revocations ?? [])
    }
    func saveGuestBLEReceipt(_ intent: ActionIntent, record: BLERevocation, code: UInt8) throws {
        guard storageReady, let i = guests.firstIndex(where: { $0.id == intent.guestID }), var cache = guests[i].bleCache else { throw BLETransportFailure.cancelled }
        try cache.acknowledgeRevocation(record, code: code)
        var updated = guests; updated[i].bleCache = cache; try save(updated)
    }
    func beginBLEGuestAction(_ intent: ActionIntent, proofHash: String) throws -> String {
        guard bleAuthorizedIntent == intent.id else { throw BLETransportFailure.cancelled }
        _ = try guestBLEMaterial(intent)
        guard let i = guests.firstIndex(where: { $0.id == intent.guestID }), var cache = guests[i].bleCache else { throw BLETransportFailure.cancelled }
        try cache.consume(proof: proofHash, epoch: UInt64(max(0, Date().timeIntervalSince1970)))
        var updated = guests; updated[i].bleCache = cache
        let actionKey = "ble-guest:" + UUID().uuidString
        let previous = journal
        journal.insert(JournalEntry(who: "Я", what: intent.object.label, actionKey: actionKey,
            result: "Результат Bluetooth-команды не получен", level: "warning"), at: 0)
        journal = Array(journal.prefix(500))
        do { try save(updated) } catch { journal = previous; throw error }
        bleAuthorizedIntent = nil
        return actionKey
    }
    func isBLEGuestAuthorized(_ id: UUID) -> Bool { canManageGuestAccess && bleAuthorizedIntent == id }
    func finishBLEGuestAuthorization(_ id: UUID) { if bleAuthorizedIntent == id { bleAuthorizedIntent = nil } }

    func refreshOwnerBLEDecision(server: String, record: BLERevocation) async {
        guard canManageGuestAccess, !ownerBusy, !busy else { return }
        ownerBusy = true; defer { ownerBusy = false }
        await syncOwner(server)
        guard ownerMessages[server] == nil, let i = owners.firstIndex(where: { $0.server == server }),
              let current = owners[i].bleRevocations?.first(where: { $0.id == record.id }), current.revoked == record.revoked,
              let object = owners[i].objects?.first(where: { $0.bleDeviceID == record.deviceID }), let numberID = object.numberID else {
            errorMessage = "Не удалось подтвердить текущее решение. Обновите данные владельца."; return
        }
        let root = owners[i].issuedKeys?.first(where: { $0.guestID == Int(record.guestID) })?.id
        let leaf = owners[i].delegatedKeys?.first(where: { $0.guestID == Int(record.guestID) })?.id
        guard let keyID = root ?? leaf else { errorMessage = "Для обновления решения нужна резервная копия выданного ключа."; return }
        do {
            var updated = owners
            try updated[i].queueBLEDecision(keyID: keyID, revoked: record.revoked, restrictingObjectIDs: [numberID], forceVersion: true)
            try saveOwners(updated)
        } catch { errorMessage = "Не удалось обновить решение. Разрешение возможно только для действующего подтверждённого ключа." }
    }

    func saveOwnerBLEReceipt(server: String, record: BLERevocation, code: UInt8) throws {
        guard storageReady, let i = owners.firstIndex(where: { $0.server == server }),
              let j = owners[i].bleRevocations?.firstIndex(where: { $0.id == record.id && $0.version == record.version && $0.signature == record.signature }) else { throw BLETransportFailure.cancelled }
        var updated = owners
        try updated[i].bleRevocations![j].receiveControllerResult(code)
        try saveOwners(updated)
    }

    func ownerManualActionAllowed(_ object: OwnerObject, server: String, action: GuestAction) -> Bool {
        do {
            let policy = try OwnerManualPolicy(object.localPolicy)
            if let reason = policy.blockedReason { rejectOwnerAction(object.id, reason); return false }
            if policy.authentication != nil {
                guard foreground, let active = activeOwnerAction, active.server == server,
                      active.object == object, active.action == action else {
                    rejectOwnerAction(object.id, "Требуется подтверждение личности."); return false
                }
            }
            return true
        } catch { rejectOwnerAction(object.id, "Не удалось проверить защищённые правила владельца."); return false }
    }
    func beginBLEOwnerAction(server: String, objectID: UUID, proofHash: String) throws -> String {
        guard canManageGuestAccess, let i = owners.firstIndex(where: { $0.server == server }),
              let j = owners[i].objects?.firstIndex(where: { $0.id == objectID }),
              let object = owners[i].objects?[j], object.kind == "ble", object.ownerCardAvailable,
              !(object.bleProofs ?? []).contains(proofHash), ownerManualActionAllowed(object, server: server, action: .toggle) else { throw GuestCrypto.Failure.invalidEnvelope }
        let label = (try object.metadata(masterKey: owners[i].masterKey)["label"] as? String) ?? "Bluetooth-объект"
        var updated = owners
        // Fresh NONCE reads are unique on the controller; retain more than its
        // 16-entry accepted nonce window locally as a second replay check.
        updated[i].objects![j].bleProofs = Array(((object.bleProofs ?? []) + [proofHash]).suffix(64))
        let actionKey = "ble-owner:" + UUID().uuidString
        let previous = journal
        journal.insert(JournalEntry(who: "Я", what: label, actionKey: actionKey,
            result: "Результат Bluetooth-команды не получен", level: "warning"), at: 0)
        journal = Array(journal.prefix(500))
        do { try saveOwners(updated) } catch { journal = previous; throw error }
        return actionKey
    }

    func saveBLEPairing(_ record: BLEPairingRecord, server: String) throws {
        guard canManageGuestAccess, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              owners[index].credentials != nil else { throw BackupFailure.busy }
        var updated = owners
        var records = updated[index].blePairings ?? []
        if let offset = records.firstIndex(where: { $0.id == record.id }) {
            guard records[offset].wrappedSecret == record.wrappedSecret, records[offset].packet == record.packet,
                  records[offset].deviceID == record.deviceID, records[offset].peerPublic == record.peerPublic,
                  records[offset].phase != .confirmed || record.phase == .confirmed,
                  records[offset].phase != .sent || record.phase != .prepared,
                  records[offset].objectID == nil || records[offset].objectID == record.objectID else { throw BackupFailure.conflictingAccess }
            records[offset] = record
        } else {
            guard !records.contains(where: { $0.peripheralID == record.peripheralID && $0.objectID == nil }),
                  !records.contains(where: { $0.deviceID == record.deviceID }),
                  !(updated[index].objects ?? []).contains(where: { $0.bleDeviceID == record.deviceID }) else { throw BackupFailure.conflictingAccess }
            records.append(record)
        }
        updated[index].blePairings = records
        try saveOwners(updated)
    }

    func registerPairedBLE(server: String, pairingID: UUID) async -> Bool {
        guard canManageGuestAccess, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].blePairings?.firstIndex(where: { $0.id == pairingID }),
              let record = owners[index].blePairings?[offset], record.phase == .confirmed else { return false }
        ownerBusy = true; defer { ownerBusy = false }
        do {
            if let objectID = record.objectID {
                // A previous server request may have succeeded. The ordinary
                // object screen owns explicit recovery; never create a second row.
                return owners[index].objects?.contains(where: { $0.id == objectID && $0.numberID != nil }) == true
            }
            let object = try OwnerObject(pairing: record, masterKey: owners[index].masterKey)
            var updated = owners
            updated[index].objects = (updated[index].objects ?? []) + [object]
            updated[index].blePairings![offset].objectID = object.id
            try saveOwners(updated)
            return await sendOwnerObject(server: server, objectID: object.id)
        } catch {
            errorMessage = "Не удалось сохранить Bluetooth-объект. Секрет привязки сохранён; новый pair не выполняется."
            return false
        }
    }

    func addOwner(server: String, accessCode: String) async -> Bool {
        guard storageReady, !ownerBusy else { return false }
        let host: String
        do { host = try GuestInvite.normalizeServer(server) }
        catch { errorMessage = "Укажите HTTPS-адрес сервера без пути, логина и пароля."; return false }
        guard !owners.contains(where: { $0.server == host }) else {
            errorMessage = "Этот сервер уже добавлен. Повторная регистрация не выполнялась."
            return false
        }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            // Save a reservation BEFORE sending. A lost reply survives process death.
            try saveOwners(owners + [try OwnerAccount(server: host)])
        } catch {
            errorMessage = "Не удалось сохранить сервер в защищённом хранилище. Регистрация не отправлялась."
            return false
        }
        do {
            let credentials = try await ownerAPI.register(server: host, accessCode: accessCode)
            unsavedOwnerCredentials[host] = credentials
            try persistOwnerCredentials(host)
            await syncOwner(host)
            return true
        } catch {
            ownerMessages[host] = unsavedOwnerCredentials[host] == nil
                ? "Ответ о регистрации не получен или не подтверждён. Повторная регистрация заблокирована, чтобы не создать второго владельца."
                : "Ответ получен, но сохранить доступ не удалось. Нажмите «Сохранить доступ», не закрывая приложение."
            errorMessage = ownerMessages[host]
            return false
        }
    }

    private func persistOwnerCredentials(_ host: String) throws {
        guard let credentials = unsavedOwnerCredentials[host],
              let index = owners.firstIndex(where: { $0.server == host }) else { return }
        var updated = owners
        updated[index].credentials = credentials
        try saveOwners(updated)
        unsavedOwnerCredentials.removeValue(forKey: host)
        ownerMessages.removeValue(forKey: host)
    }

    func canSaveOwnerAccess(_ host: String) -> Bool { unsavedOwnerCredentials[host] != nil }

    func retrySavingOwnerAccess(_ host: String) async {
        guard storageReady, !ownerBusy else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        do { try persistOwnerCredentials(host); await syncOwner(host) }
        catch { errorMessage = "Не удалось сохранить доступ. Регистрация повторно не отправлялась." }
    }

    private func syncOwner(_ host: String) async {
        guard let credentials = owners.first(where: { $0.server == host })?.credentials else { return }
        do {
            let fingerprint = GuestCrypto.hash(identity + Data(host.utf8))
            let data = try await ownerAPI.sync(server: host, credentials: credentials, fingerprint: fingerprint)
            let snapshot = try OwnerSnapshot.decode(data)
            guard pendingRestore == nil else { return }
            guard let index = owners.firstIndex(where: { $0.server == host }) else { return }
            let previousObjects = owners[index].objects ?? []
            var updated = owners
            try updated[index].reconcileObjects(snapshot)
            updated[index].reservedGuestIDs = allReservedGuestIDs()
            try updated[index].reconcileAndroidKeys(snapshot)
            try updated[index].reconcileIssuedKeys(snapshot)
            let unverified = try updated[index].reconcileDelegatedKeys(snapshot)
            try updated[index].reconcileBLERestoration()
            updated[index].lastSynced = Date()
            try saveOwners(updated)
            let pendingIDs = Set((updated[index].objects ?? []).filter { $0.pending != nil }.map(\.id))
            for object in previousObjects where !pendingIDs.contains(object.id) && unsavedOwnerObjects[object.id] == nil {
                ownerObjectMessages.removeValue(forKey: object.id)
            }
            for key in updated[index].issuedKeys ?? [] where key.pending == nil && unsavedOwnerKeys[key.id] == nil {
                ownerKeyMessages.removeValue(forKey: key.id)
            }
            unverifiedOwnerDelegations[host] = unverified
            for key in updated[index].delegatedKeys ?? [] where key.state == .ready || key.state == .revoked {
                ownerDelegationMessages.removeValue(forKey: key.id)
            }
            ownerSnapshots[host] = snapshot
            ownerMessages.removeValue(forKey: host)
        } catch {
            let code = (error as? OwnerAPI.Failure)?.code
            ownerMessages[host] = ["evicted", "wrong_device"].contains(code ?? "")
                ? "Доступ закреплён за другим устройством. Нужен явный перенос доступа."
                : (code == "auth" ? "Сервер отклонил доступ владельца. Новая регистрация автоматически не создаётся."
                   : "Не удалось обновить данные сервера. Сохранённый доступ не изменён.")
        }
    }

    func refreshOwners() async {
        guard storageReady, foreground, !ownerBusy else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        for owner in owners where !owner.registrationPending {
            await syncOwner(owner.server)
            await flushOwnerObjectSettings(server: owner.server)
        }
    }

    func createOwnerObject(server: String, label: String, kind: String, phone: String, url: String, secret: String, claimCode: String, registerDevice: Bool = false,
                           webhookMode: String = "server", webhookToggle: Bool = false) async -> Bool {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server && $0.credentials != nil }) else { return false }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            let draft = try OwnerObject(masterKey: owners[index].masterKey, label: label, kind: kind, phone: phone, url: url, secret: secret, claimCode: claimCode, registerDevice: registerDevice,
                webhookMode: webhookMode, webhookToggle: webhookToggle)
            var updated = owners
            updated[index].objects = (updated[index].objects ?? []) + [draft]
            try saveOwners(updated)
            return await sendOwnerObject(server: server, objectID: draft.id)
        } catch {
            errorMessage = "Не удалось сохранить объект. Проверьте поля и доступ к защищённому хранилищу."
            return false
        }
    }

    func renameOwnerObject(server: String, objectID: UUID, label: String, preset: Int? = nil) async -> Bool {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID }) else { return false }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var updated = owners
            let masterKey = updated[index].masterKey
            try updated[index].objects![offset].updatePresentation(label: label, preset: preset, masterKey: masterKey)
            try saveOwners(updated)
            return await sendOwnerObject(server: server, objectID: objectID)
        } catch { errorMessage = "Не удалось сохранить изменение. Сначала обновите данные сервера."; return false }
    }

    func updateOwnerObject(server: String, objectID: UUID, draft: OwnerObjectEdit) async -> Bool {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID }) else { return false }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var updated = owners
            let masterKey = updated[index].masterKey
            try updated[index].objects![offset].updateConfiguration(draft, masterKey: masterKey)
            if let numberID = updated[index].objects![offset].numberID { updated[index].queueObjectSettings(numberID: numberID) }
            try saveOwners(updated)
            let saved = await sendOwnerObject(server: server, objectID: objectID)
            if saved { await flushOwnerObjectSettings(server: server) }
            return saved
        } catch {
            ownerObjectMessages[objectID] = "Не удалось сохранить настройки. Объект мог измениться; обновите данные и откройте настройки снова."
            return false
        }
    }

    /// Metadata/template publication is idempotent. Each queue token survives a
    /// restart and distinguishes an in-flight old version from a newer edit.
    /// This queue never sends an actuator command or creates a guest identity.
    private func flushOwnerObjectSettings(server: String) async {
        guard foreground, pendingRestore == nil,
              let start = owners.first(where: { $0.server == server }) else { return }
        for keyID in (start.bundleRefreshQueue ?? [:]).keys.sorted() {
            guard let index = owners.firstIndex(where: { $0.server == server }),
                  let token = owners[index].bundleRefreshQueue?[keyID],
                  let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id.uuidString == keyID }) else { continue }
            let retryID = server + "|" + keyID
            if let next = ownerBundleRetryAfter[retryID], next > Date() { continue }
            let key = owners[index].issuedKeys![offset]
            if editingOwnerKeys.contains(key.id) { continue }
            do {
                var updated = owners
                if key.state == .revoked || (key.pending == nil && key.objectSettingsToken == token) {
                    updated[index].bundleRefreshQueue?.removeValue(forKey: keyID)
                    try saveOwners(updated); ownerBundleRetryAfter.removeValue(forKey: retryID)
                    ownerBundleRetryAttempts.removeValue(forKey: retryID)
                    continue
                }
                if key.pending == nil {
                    let owner = updated[index]
                    try updated[index].issuedKeys![offset].refreshObjectSettings(owner: owner)
                    updated[index].issuedKeys![offset].objectSettingsToken = token
                    try saveOwners(updated)
                } else if key.pending != .keyEdit || key.objectSettingsToken == nil { continue }
                if owners[index].issuedKeys![offset].sent { continue }
                deferOwnerSettingsRetry(retryID)
                _ = await sendOwnerKey(server: server, keyID: key.id)
            } catch {
                deferOwnerSettingsRetry(retryID)
                ownerKeyMessages[key.id] = "Настройки сохранены на iPhone. Обновление гостевого ключа ожидает синхронизации."
            }
        }
    }

    private func deferOwnerSettingsRetry(_ id: String) {
        let attempt = min(6, ownerBundleRetryAttempts[id] ?? 0)
        ownerBundleRetryAfter[id] = Date().addingTimeInterval(min(1800, 30 * pow(2, Double(attempt))))
        ownerBundleRetryAttempts[id] = attempt + 1
    }

    private func scheduleOwnerSettingsRefresh() {
        guard ownerSettingsTask == nil, foreground, owners.contains(where: { !($0.bundleRefreshQueue ?? [:]).isEmpty }) else { return }
        let generation = UUID()
        ownerSettingsTaskGeneration = generation
        ownerSettingsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                guard let self, self.foreground else { break }
                guard self.owners.contains(where: { !($0.bundleRefreshQueue ?? [:]).isEmpty }) else { break }
                guard !self.ownerBusy, !self.busy, self.pendingRestore == nil else { continue }
                self.ownerBusy = true
                for server in self.owners.map(\.server) {
                    await self.syncOwner(server)
                    await self.flushOwnerObjectSettings(server: server)
                }
                self.ownerBusy = false
            }
            if self?.ownerSettingsTaskGeneration == generation {
                self?.ownerSettingsTask = nil; self?.ownerSettingsTaskGeneration = nil
            }
        }
    }

    func deleteOwnerObject(server: String, objectID: UUID) async {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID }),
              owners[index].objects![offset].pending == nil, owners[index].objects![offset].available != false else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var updated = owners
            if let numberID = updated[index].objects?[offset].numberID, updated[index].objects?[offset].kind == "ble" {
                let roots = (updated[index].issuedKeys ?? []).filter { $0.numberIDs.contains(numberID) }.map(\.id)
                let leaves = (updated[index].delegatedKeys ?? []).filter { $0.numberIDs.contains(numberID) }.map(\.id)
                for keyID in roots + leaves { try updated[index].queueBLEDecision(keyID: keyID, revoked: true, restrictingObjectIDs: [numberID]) }
            }
            updated[index].objects![offset].pending = .delete
            updated[index].objects![offset].sent = false
            try saveOwners(updated)
            _ = await sendOwnerObject(server: server, objectID: objectID)
        } catch { errorMessage = "Не удалось сохранить запрос удаления. На сервер он не отправлялся." }
    }

    func canSaveOwnerObjectResult(_ objectID: UUID) -> Bool { unsavedOwnerObjects[objectID] != nil }

    func retrySavingOwnerObjectResult(server: String, objectID: UUID) async {
        guard storageReady, !ownerBusy, let result = unsavedOwnerObjects[objectID],
              let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID }) else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var updated = owners
            var recovered = result
            // Local automation/proof edits made after the network reply belong
            // to the current phone, not the older unsaved acknowledgement.
            recovered.localPolicy = updated[index].objects![offset].localPolicy
            recovered.bleProofs = updated[index].objects![offset].bleProofs
            updated[index].objects![offset] = recovered
            try saveOwners(updated)
            unsavedOwnerObjects.removeValue(forKey: objectID)
            ownerObjectMessages.removeValue(forKey: objectID)
            if result.pending == .create && !result.sent { _ = await sendOwnerObject(server: server, objectID: objectID) }
            else { await syncOwner(server) }
        } catch { errorMessage = "Не удалось сохранить полученный результат. Повторный запрос не отправлялся." }
    }

    func retryPreparedOwnerObject(server: String, objectID: UUID) async {
        guard storageReady, !ownerBusy else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        _ = await sendOwnerObject(server: server, objectID: objectID)
    }

    /// Explicitly discard only an unsent or definitively rejected operation.
    func cancelOwnerObjectChange(server: String, objectID: UUID) {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID }),
              let object = owners[index].objects?[offset], object.pending != nil, !object.sent,
              unsavedOwnerObjects[objectID] == nil else { return }
        if object.numberID == nil && object.routing["device_id_ref"] != nil {
            errorMessage = "Контроллер уже привязан. Завершите сохранённую попытку создания объекта."
            return
        }
        do {
            var updated = owners
            if object.numberID == nil {
                updated[index].objects!.remove(at: offset)
                updated[index].blePairings = updated[index].blePairings?.map { record in
                    var record = record
                    if record.objectID == objectID { record.objectID = nil }
                    return record
                }
            }
            else if object.pending == .update {
                if object.editBaseline != nil {
                    try updated[index].objects![offset].cancelConfigurationUpdate()
                    try saveOwners(updated)
                    ownerObjectMessages.removeValue(forKey: objectID)
                    return
                }
                guard let row = ownerSnapshots[server]?.rows.first(where: { ($0["id"] as? Int) == object.numberID }),
                      let cipher = row["data_cipher"] as? String else { return }
                updated[index].objects![offset].cipher = cipher
                updated[index].objects![offset].pending = nil
                updated[index].objects![offset].sent = false
                try updated[index].reconcileObjects(ownerSnapshots[server]!)
            } else { updated[index].objects![offset].pending = nil }
            try saveOwners(updated)
            ownerObjectMessages.removeValue(forKey: objectID)
        } catch { errorMessage = "Не удалось сохранить отмену. Защищённый доступ не удалён." }
    }

    private func sendOwnerObject(server: String, objectID: UUID) async -> Bool {
        guard let index = owners.firstIndex(where: { $0.server == server }), let credentials = owners[index].credentials,
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID }),
              var object = owners[index].objects?[offset], let operation = object.pending, !object.sent else { return false }
        do {
            let body = try object.request()
            object.sent = true
            var updated = owners
            updated[index].objects![offset] = object
            try saveOwners(updated)
            let response = try await ownerAPI.mutate(server: server, credentials: credentials,
                fingerprint: GuestCrypto.hash(identity + Data(server.utf8)), operation: operation, body: body)
            guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let latestIndex = owners.firstIndex(where: { $0.server == server }),
                  let latestOffset = owners[latestIndex].objects?.firstIndex(where: { $0.id == objectID }) else { throw GuestCrypto.Failure.invalidEnvelope }
            updated = owners
            switch operation {
            case .deviceRegister:
                guard let key = json["device_key"] as? String, let secret = json["device_secret"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
                try updated[latestIndex].objects![latestOffset].acceptDeviceRegistration(id: OwnerObject.replyID(json["device_id"]),
                    key: key, secret: secret, masterKey: owners[latestIndex].masterKey)
            case .keyCreate, .keyEdit, .keyMode, .keyRevoke, .hostClaim, .messageSend: throw GuestCrypto.Failure.invalidEnvelope
            case .claim:
                let id = try OwnerObject.replyID(json["device_id"])
                try updated[latestIndex].objects![latestOffset].acceptClaim(deviceID: id)
            case .create:
                let id = try OwnerObject.replyID(json["id"])
                updated[latestIndex].objects![latestOffset].numberID = id
                updated[latestIndex].objects![latestOffset].pending = nil
                updated[latestIndex].objects![latestOffset].sent = false
            case .update, .delete:
                guard (json["ok"] as? NSNumber)?.boolValue == true else { throw GuestCrypto.Failure.invalidEnvelope }
                // Keep the pending operation until sync confirms its actual outcome.
            }
            unsavedOwnerObjects[objectID] = updated[latestIndex].objects![latestOffset]
            try saveOwners(updated)
            unsavedOwnerObjects.removeValue(forKey: objectID)
            ownerObjectMessages.removeValue(forKey: objectID)
            if operation == .claim || operation == .deviceRegister { return await sendOwnerObject(server: server, objectID: objectID) }
            await syncOwner(server)
            return true
        } catch {
            let failure = error as? OwnerAPI.Failure
            let code = failure?.code ?? ""
            let rejected = (400..<500).contains(failure?.status ?? 0) && ["bad_input", "invalid_cipher_format", "webhook_url_forbidden", "webhook_secret_required", "forbidden", "device_not_owned", "limit_reached", "auth", "not_found", "conflict", "stale_data_cipher", "wrong_device", "evicted"].contains(code)
            if rejected, let i = owners.firstIndex(where: { $0.server == server }), let j = owners[i].objects?.firstIndex(where: { $0.id == objectID }) {
                var updated = owners
                updated[i].objects![j].sent = false
                try? saveOwners(updated)
            }
            ownerObjectMessages[objectID] = unsavedOwnerObjects[objectID] != nil
                ? "Результат получен, но не сохранён. Нажмите «Сохранить результат», не закрывая приложение."
                : code == "stale_data_cipher" ? "Объект уже изменён. Обновите данные и отмените своё изменение перед повторной правкой."
                : (rejected ? "Сервер отклонил запрос. Проверьте данные; неподтверждённое изменение можно отменить."
                   : "Результат не подтверждён. Обновите данные сервера: повторный запрос автоматически не отправляется.")
            errorMessage = ownerObjectMessages[objectID]
            return false
        }
    }

    func approveDelegatedKey(server: String, keyID: UUID, retry: Bool = false) async {
        guard storageReady, !ownerBusy, !busy else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        await syncOwner(server)
        guard ownerMessages[server] == nil,
              let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].delegatedKeys?.firstIndex(where: { $0.id == keyID }),
              let credentials = owners[index].credentials else { return }
        let key = owners[index].delegatedKeys![offset]
        guard key.state == .awaiting, key.revocationPending != true else { return }
        guard !key.sent || retry else {
            ownerDelegationMessages[keyID] = "Результат передачи связки пока не подтверждён. Обновление не повторяет запрос."; return
        }
        do {
            var updated = owners
            updated[index].delegatedKeys![offset].sent = true
            try saveOwners(updated)
        } catch { ownerDelegationMessages[keyID] = "Не удалось сохранить связку. На сервер она не отправлялась."; return }
        do {
            let body = try owners[index].delegatedKeys![offset].request()
            _ = try await ownerAPI.mutate(server: server, credentials: credentials,
                fingerprint: backupFingerprint(server: server), operation: .keyEdit, body: body)
            await syncOwner(server)
        } catch {
            ownerDelegationMessages[keyID] = "Ответ передачи связки не подтверждён. Данные получателя сохранены; сначала обновите сервер."
        }
    }
    func revokeDelegatedKey(server: String, keyID: UUID) async {
        guard storageReady, !ownerBusy, !busy else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        await syncOwner(server)
        guard ownerMessages[server] == nil,
              let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].delegatedKeys?.firstIndex(where: { $0.id == keyID }),
              let credentials = owners[index].credentials else { return }
        let key = owners[index].delegatedKeys![offset]
        guard key.state != .revoked, key.revocationSent != true else { return }
        do {
            var updated = owners
            try updated[index].queueBLEDecision(keyID: keyID, revoked: true)
            updated[index].delegatedKeys![offset].revocationPending = true
            updated[index].delegatedKeys![offset].revocationSent = true
            updated[index].delegatedKeys![offset].state = .unavailable
            try saveOwners(updated)
        } catch { ownerDelegationMessages[keyID] = "Не удалось сохранить запрос отзыва. На сервер он не отправлялся."; return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["id": key.keyID], options: .sortedKeys)
            _ = try await ownerAPI.mutate(server: server, credentials: credentials,
                fingerprint: backupFingerprint(server: server), operation: .keyRevoke, body: body)
            await syncOwner(server)
        } catch { ownerDelegationMessages[keyID] = "Отзыв не подтверждён. На этом iPhone ключ заблокирован; обновите данные сервера." }
    }

    private func allReservedGuestIDs() -> [Int] {
        var result = Set<Int>()
        for owner in owners {
            result.formUnion(owner.reservedGuestIDs ?? [])
            result.formUnion((owner.issuedKeys ?? []).map(\.guestID))
            result.formUnion((owner.delegatedKeys ?? []).map(\.guestID))
            result.formUnion((owner.androidKeys ?? []).compactMap(\.guestID))
            result.formUnion((owner.bleRevocations ?? []).map { Int($0.guestID) })
        }
        return result.sorted()
    }
    func createOwnerKey(server: String, label: String, numberIDs: [Int], welcome: String, nativeOnly: Bool, confirmation: Bool, access: [Int: KeyObjectAccess]? = nil, settings: OwnerKeyConfiguration? = nil) async -> Bool {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server && $0.credentials != nil }) else { return false }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var authority = owners[index]
            authority.reservedGuestIDs = allReservedGuestIDs()
            let key = try OwnerIssuedKey(owner: authority, label: label, numberIDs: numberIDs, welcome: welcome, nativeOnly: nativeOnly, confirmation: confirmation, access: access, settings: settings)
            var updated = owners
            updated[index].reservedGuestIDs = authority.reservedGuestIDs
            updated[index].issuedKeys = (updated[index].issuedKeys ?? []) + [key]
            try saveOwners(updated)
            return await sendOwnerKey(server: server, keyID: key.id)
        } catch {
            errorMessage = "Не удалось подготовить ключ. Выберите сохранённые объекты; контроллеру нужен защищённый пропуск."
            return false
        }
    }

    private func keyObjectIDs(owner: OwnerAccount, keyID: UUID) -> [Int] { owner.issuedKeys?.first(where: { $0.id == keyID })?.numberIDs ?? [] }
    func editOwnerKey(server: String, keyID: UUID, label: String, numberIDs: [Int], welcome: String, confirmation: Bool?, access: [Int: KeyObjectAccess]? = nil, settings: OwnerKeyConfiguration? = nil) async -> Bool {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id == keyID }) else { return false }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            let owner = owners[index]
            var updated = owners
            let oldIDs = keyObjectIDs(owner: owner, keyID: keyID)
            let addedBLE = Set((owner.objects ?? []).filter { $0.kind == "ble" && numberIDs.contains($0.numberID ?? -1) && !oldIDs.contains($0.numberID ?? -1) }.compactMap(\.numberID))
            if !addedBLE.isEmpty { updated[index].scheduleBLERestoration(keyID: keyID, objectIDs: addedBLE) }
            let removedBLE = (owner.objects ?? []).filter { $0.kind == "ble" && keyObjectIDs(owner: owner, keyID: keyID).contains($0.numberID ?? -1) && !numberIDs.contains($0.numberID ?? -1) }
            if !removedBLE.isEmpty { try updated[index].queueBLEDecision(keyID: keyID, revoked: true, restrictingObjectIDs: Set(removedBLE.compactMap(\.numberID))) }
            try updated[index].issuedKeys![offset].edit(owner: owner, label: label, numberIDs: numberIDs, welcome: welcome, confirmation: confirmation, access: access, settings: settings)
            if settings != nil { updated[index].issuedKeys![offset].objectSettingsToken = updated[index].bundleRefreshQueue?[keyID.uuidString] }
            try saveOwners(updated)
            return await sendOwnerKey(server: server, keyID: keyID)
        } catch { errorMessage = "Не удалось подготовить изменение. Проверьте выбранные объекты и состояние ключа."; return false }
    }

    func renewOwnerBLEKey(server: String, keyID: UUID) async {
        guard canManageGuestAccess, !ownerBusy, !busy,
              let i = owners.firstIndex(where: { $0.server == server }),
              let j = owners[i].issuedKeys?.firstIndex(where: { $0.id == keyID }) else { return }
        ownerBusy = true; defer { ownerBusy = false }
        do {
            var updated = owners
            try updated[i].issuedKeys![j].renewBLE(owner: owners[i])
            try saveOwners(updated)
            _ = await sendOwnerKey(server: server, keyID: keyID)
        } catch { errorMessage = "Не удалось подготовить продление. Ключ должен быть активен и подтверждён сервером." }
    }

    func setOwnerKeyMode(server: String, keyID: UUID, paused: Bool) async {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id == keyID }),
              let key = owners[index].issuedKeys?[offset], key.keyID != nil, key.pending == nil, key.state != .revoked else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var updated = owners
            if paused {
                try updated[index].queueBLEDecision(keyID: keyID, revoked: true)
                updated[index].bleRestorePending?.removeAll { $0 == keyID }
            } else {
                updated[index].scheduleBLERestoration(keyID: keyID)
            }
            updated[index].issuedKeys![offset].pending = .keyMode
            updated[index].issuedKeys![offset].pendingMode = paused ? "off" : "auto"
            updated[index].issuedKeys![offset].sent = false
            try saveOwners(updated)
            _ = await sendOwnerKey(server: server, keyID: keyID)
        } catch { errorMessage = "Не удалось сохранить изменение доступа. Запрос не отправлялся." }
    }

    func revokeOwnerKey(server: String, keyID: UUID) async {
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id == keyID }),
              let key = owners[index].issuedKeys?[offset], key.keyID != nil, key.state != .revoked, unsavedOwnerKeys[keyID] == nil else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var updated = owners
            try updated[index].queueBLEDecision(keyID: keyID, revoked: true)
            updated[index].bleRestorePending?.removeAll { $0 == keyID }
            updated[index].issuedKeys![offset].pending = .keyRevoke
            updated[index].issuedKeys![offset].pendingMode = nil
            updated[index].issuedKeys![offset].sent = false
            try saveOwners(updated)
            _ = await sendOwnerKey(server: server, keyID: keyID)
        } catch { errorMessage = "Не удалось сохранить отзыв. Доступ ещё не подтверждён как отозванный." }
    }

    func canSaveOwnerKeyResult(_ keyID: UUID) -> Bool { unsavedOwnerKeys[keyID] != nil }

    func retrySavingOwnerKeyResult(server: String, keyID: UUID) async {
        guard storageReady, !ownerBusy, let result = unsavedOwnerKeys[keyID],
              let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id == keyID }) else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        do {
            var updated = owners
            var recovered = result
            let current = updated[index].issuedKeys![offset]
            recovered.automationTemplates = current.automationTemplates
            recovered.streamAllowed = current.streamAllowed
            recovered.bleTokenLifetimes = current.bleTokenLifetimes; recovered.callPreferences = current.callPreferences
            updated[index].issuedKeys![offset] = recovered
            try saveOwners(updated)
            unsavedOwnerKeys.removeValue(forKey: keyID)
            await syncOwner(server)
        } catch { errorMessage = "Не удалось сохранить результат. Повторный запрос не отправлялся." }
    }

    func retryPreparedOwnerKey(server: String, keyID: UUID) async {
        guard storageReady, !ownerBusy else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        _ = await sendOwnerKey(server: server, keyID: keyID)
    }

    func discardUnsentOwnerKey(server: String, keyID: UUID) {
        guard storageReady, !ownerBusy, unsavedOwnerKeys[keyID] == nil,
              let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id == keyID }),
              let key = owners[index].issuedKeys?[offset], key.keyID == nil, !key.sent else { return }
        do {
            var updated = owners
            updated[index].issuedKeys!.remove(at: offset)
            try saveOwners(updated)
            ownerKeyMessages.removeValue(forKey: keyID)
        } catch { errorMessage = "Не удалось сохранить отмену." }
    }

    private func sendOwnerKey(server: String, keyID: UUID) async -> Bool {
        guard let index = owners.firstIndex(where: { $0.server == server }), let credentials = owners[index].credentials,
              let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id == keyID }),
              var key = owners[index].issuedKeys?[offset], let operation = key.pending, !key.sent else { return false }
        do {
            let body = try key.request(masterKey: owners[index].masterKey)
            key.sent = true
            var updated = owners
            updated[index].issuedKeys![offset] = key
            try saveOwners(updated)
            let response = try await ownerAPI.mutate(server: server, credentials: credentials,
                fingerprint: GuestCrypto.hash(identity + Data(server.utf8)), operation: operation, body: body)
            guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let i = owners.firstIndex(where: { $0.server == server }),
                  let j = owners[i].issuedKeys?.firstIndex(where: { $0.id == keyID }) else { throw GuestCrypto.Failure.invalidEnvelope }
            updated = owners
            if operation == .keyCreate { updated[i].issuedKeys![j].keyID = try OwnerObject.replyID(json["id"]) }
            else { guard (json["ok"] as? NSNumber)?.boolValue == true else { throw GuestCrypto.Failure.invalidEnvelope } }
            unsavedOwnerKeys[keyID] = updated[i].issuedKeys![j]
            try saveOwners(updated)
            unsavedOwnerKeys.removeValue(forKey: keyID)
            await syncOwner(server)
            guard let confirmed = owners.first(where: { $0.server == server })?.issuedKeys?.first(where: { $0.id == keyID }) else { return false }
            return confirmed.pending == nil
        } catch {
            let failure = error as? OwnerAPI.Failure
            let rejected = (400..<500).contains(failure?.status ?? 0) && ["bad_input", "bad_numbers", "limit_reached", "auth", "forbidden", "not_found", "invalid_cipher_format", "unsupported_suite", "bad_key_hash", "bad_sign_pub", "wrong_device", "evicted"].contains(failure?.code ?? "")
            if rejected, let i = owners.firstIndex(where: { $0.server == server }), let j = owners[i].issuedKeys?.firstIndex(where: { $0.id == keyID }) {
                var updated = owners
                updated[i].issuedKeys![j].sent = false
                try? saveOwners(updated)
            }
            ownerKeyMessages[keyID] = unsavedOwnerKeys[keyID] != nil
                ? "Ответ получен, но не сохранён. Сохраните результат, не закрывая приложение."
                : (rejected ? "Сервер отклонил запрос. Доступ не подтверждён."
                   : "Результат запроса не подтверждён. Обновите данные сервера; повторный запрос автоматически не отправляется.")
            errorMessage = ownerKeyMessages[keyID]
            return false
        }
    }

    func add(_ text: String) async -> Bool {
        guard storageReady, !busy else { return false }
        do {
            let invite = try GuestInvite.parse(text)
            if !guests.contains(where: { $0.id == invite.id }) {
                // Persist credentials before binding, including when the bind response is lost.
                try save(guests + [SavedGuest(invite: invite)])
            } else if let guest = guests.first(where: { $0.id == invite.id }) {
                var preferences = objectPreferences
                preferences.reveal(guest.objects.map { .received(guestID: guest.id, objectID: $0.id) })
                try save(guests, preferences: preferences)
            }
            await refresh()
            return true
        } catch {
            errorMessage = "Не удалось сохранить ключ. Проверьте, что ссылка скопирована полностью."
            return false
        }
    }

    func refresh() async {
        guard storageReady, foreground, !busy, !guests.isEmpty else { return }
        pauseGuestSessions()
        foreground = true
        errorMessage = nil
        syncFailure = nil
        busy = true
        writePreviewStatus()
        defer {
            busy = false
            writePreviewStatus()
            if foreground { ownerControl.resume() }
            if foreground && resumeRequested {
                resumeRequested = false
                Task { await refresh() }
            }
        }
        for entry in guests {
            connections[entry.id] = .connecting
            do {
                let fingerprint = GuestCrypto.hash(identity + Data(entry.invite.server.utf8))
                try await api.bind(invite: entry.invite, fingerprint: fingerprint)
                guard foreground else { return }
                let bundleReply = try await api.bundleWithDepth(invite: entry.invite, fingerprint: fingerprint)
                let bundle = bundleReply.contents
                guard foreground else { return }
                if let b = try JSONSerialization.jsonObject(with: bundle) as? [String: Any],
                   let networks = b["net_block"] as? [Any], !networks.isEmpty {
                    throw GuestAPI.Failure(status: 0, code: "network_policy_unsupported")
                }
                let snapshot = try await api.snapshot(invite: entry.invite, fingerprint: fingerprint)
                guard foreground else { return }
                let objects = try GuestObjects.decode(bundle: bundle, snapshot: snapshot)
                let message = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any]
                var updated = guests
                if let index = updated.firstIndex(where: { $0.id == entry.id }) {
                    try updateGuestMaterial(&updated[index], objects: objects, bundle: bundle, snapshot: snapshot)
                    updated[index].objects = objects
                    updated[index].incomingDepth = bundleReply.depth
                    updated[index].paused = message?["mode"] as? String == "off"
                    updated[index].checkedAt = Date()
                    try save(updated)
                }
                if foreground { startWatching(entry: entry, bundle: bundle) }
            } catch {
                let code = (error as? GuestAPI.Failure)?.code ?? (error is KeychainStore.Failure ? "storage_error" : "connection_failed")
                syncFailure = safeDiagnosticCode(code)
                // A temporary read-connection failure uses the inline connection state.
                // Reconnection must be able to recover without a stale blocking alert.
                if GuestEvent.terminalReasons.contains(code) || ["network_policy_unsupported", "paused", "storage_error"].contains(code) {
                    errorMessage = readable(code)
                }
                connections[entry.id] = .offline
                if GuestEvent.terminalReasons.contains(code) || code == "network_policy_unsupported" {
                    try? markUnavailable(entry.id)
                }
                if code == "paused" {
                    var updated = guests
                    if let index = updated.firstIndex(where: { $0.id == entry.id }) { updated[index].paused = true; try? save(updated) }
                }
                if foreground && !GuestEvent.terminalReasons.contains(code) && !["network_policy_unsupported", "storage_error"].contains(code) {
                    startWatching(entry: entry, bundle: nil)
                }
            }
        }
    }

    func resume() async {
        foreground = true
        scheduleOwnerSettingsRefresh()
        if ownerBusy && busy { return }
        ownerControl.resume()
        if busy { resumeRequested = true; return }
        await refresh()
        await refreshOwners()
        ownerControl.resume()
        if !passedAccess.isEmpty { await passManager.reload() }
        await messages.retryAcknowledgements()
        delegationInbox.resume()
    }

    func suspend() {
        ownerSettingsTask?.cancel(); ownerSettingsTask = nil; ownerSettingsTaskGeneration = nil
        delegationInbox.suspend()
        ownerControl.suspend()
        pauseGuestSessions()
    }

    private func pauseGuestSessions() {
        blePairing.suspend()
        bleControl.suspend()
        bleGuestControl.suspend()
        bleAuthorizedIntent = nil
        authorizedIntent = nil; activeOwnerAction = nil
        foreground = false
        resumeRequested = false
        for id in Array(actionLinks.keys) { stopActions(id) }
        generations.removeAll()
        watchers.values.forEach { $0.cancel() }
        watchers.removeAll()
        for key in Array(connections.keys) where connections[key] != .unavailable { connections[key] = .offline }
    }

    func connection(for id: String) -> GuestConnection { connections[id] ?? .offline }

    /// Presentation only: never reserves a command or changes an error while rendering.
    func objectActionTitle(guestID: String, object: GuestObject) -> String {
        if object.kind == "ble" { return ActionIntent.displayTitle(action: .toggle, kind: "ble") }
        guard let link = actionLinks[guestID], let bundle = link.bundle, let snapshot = link.snapshot,
              let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guests.first(where: { $0.id == guestID })?.automation?[object.id]) else {
            return "Управлять"
        }
        let action = chosenGuestAction(policy: policy, numberID: object.numberID, positions: link.positions)
        return ActionIntent.displayTitle(action: action, kind: policy.kind)
    }

    func objectConnectionTitle(guestID: String, object: GuestObject) -> String {
        guard let link = actionLinks[guestID], connection(for: guestID) == .connected,
              let bundle = link.bundle, let snapshot = link.snapshot,
              let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guests.first(where: { $0.id == guestID })?.automation?[object.id]) else {
            return connection(for: guestID).title
        }
        if let reason = policy.blockedReason { return reason }
        if policy.serverWebhook { return "Сервер в сети" }
        if policy.kind == "device" { return policy.deviceID.map { link.devices.contains($0) } == true ? "Контроллер в сети" : "Контроллер не в сети" }
        return link.hostOnline ? "Телефон владельца в сети" : "Телефон владельца не в сети"
    }

    func removeKey(_ id: String) {
        guard storageReady, !busy else { return }
        do {
            let removed = guests.first(where: { $0.id == id })
            let previousReceived = receivedDelegations, previousMessages = incomingMessages
            incomingMessages.removeAll { $0.guestID == id }
            for i in receivedDelegations.indices { receivedDelegations[i].parts.removeAll { $0.guestID == id } }
            receivedDelegations.removeAll { $0.parts.isEmpty }
            var preferences = objectPreferences; preferences.removeGuest(id)
            do { try save(guests.filter { $0.id != id }, preferences: preferences) }
            catch { receivedDelegations = previousReceived; incomingMessages = previousMessages; throw error }
            for object in removed?.objects ?? [] {
                let key = AvatarCache.key(guestID: id, objectID: object.id)
                avatars.removeValue(forKey: key)
                avatarCache.remove(key)
            }
            bleGuestControl.cancel(guestID: id)
            stopActions(id)
            generations.removeValue(forKey: id)
            watchers.removeValue(forKey: id)?.cancel()
            connections.removeValue(forKey: id)
        } catch { errorMessage = "Не удалось удалить ключ из защищённого хранилища." }
    }

    func clearJournal() {
        let previous = journal
        do {
            journal = []
            try save(guests)
        } catch {
            journal = previous
            errorMessage = "Не удалось очистить журнал."
        }
    }

    /// Call only when an actual action is initiated, never for synchronization.
    func recordAction(_ entry: JournalEntry) {
        guard entry.isAction else { return }
        let previous = journal
        journal.append(entry)
        journal.sort { $0.date > $1.date }
        journal = Array(journal.prefix(500))
        do { try save(guests) }
        catch { journal = previous; errorMessage = "Не удалось сохранить журнал." }
    }

    func actionResult(actionKey: String, result: String, level: String, replace: Bool = false) {
        guard !actionKey.isEmpty, !result.isEmpty,
              let index = journal.firstIndex(where: { $0.actionKey == actionKey }),
              (replace || journal[index].result.isEmpty),
              Date().timeIntervalSince(journal[index].date) <= (replace ? 300 : 120) else { return }
        let previous = journal
        journal[index].result = result
        journal[index].level = level
        do { try save(guests) }
        catch { journal = previous; errorMessage = "Не удалось сохранить результат действия." }
    }

    func journalLabel(_ entry: JournalEntry) -> String {
        for guest in guests {
            if let object = guest.objects.first(where: { guest.id + "|" + $0.id == entry.actionKey }) { return objectLabel(.received(guest, object)) }
        }
        return entry.what
    }

    private func markUnavailable(_ id: String) throws {
        bleGuestControl.cancel(guestID: id)
        bleAuthorizedIntent = nil
        stopActions(id)
        connections[id] = .unavailable
        var updated = guests
        if let index = updated.firstIndex(where: { $0.id == id }) {
            for object in updated[index].objects {
                let key = AvatarCache.key(guestID: id, objectID: object.id)
                avatars.removeValue(forKey: key)
                avatarCache.remove(key)
            }
            updated[index].paused = true
            updated[index].bleCache = nil
            updated[index].objects = []
            try save(updated)
        }
        writePreviewStatus()
    }

    func connectInstalledGuest(_ id: String) {
        guard storageReady, foreground, watchers[id] == nil, actionLinks[id] == nil,
              let entry = guests.first(where: { $0.id == id }) else { return }
        startWatching(entry: entry, bundle: nil, bindingVerified: true)
    }

    private func startWatching(entry: SavedGuest, bundle initialBundle: Data?, bindingVerified: Bool = false) {
        let generation = UUID()
        generations[entry.id] = generation
        watchers[entry.id]?.cancel()
        watchers[entry.id] = Task { [weak self] in
            guard let self else { return }
            var bundle = initialBundle
            var bound = bindingVerified
            var delay: UInt64 = 1
            while !Task.isCancelled && self.foreground && self.generations[entry.id] == generation {
                do {
                    self.connections[entry.id] = .connecting
                    let fingerprint = GuestCrypto.hash(self.identity + Data(entry.invite.server.utf8))
                    if bundle == nil {
                        if !bound { try await self.api.bind(invite: entry.invite, fingerprint: fingerprint); bound = true }
                        bundle = try await self.api.bundle(invite: entry.invite, fingerprint: fingerprint)
                    }
                    guard !Task.isCancelled, self.foreground, self.generations[entry.id] == generation,
                          let currentBundle = bundle else { return }
                    let live = try self.api.live(invite: entry.invite, fingerprint: fingerprint)
                    let avatarQueue = AvatarRequestQueue()
                    let avatarPump = Task {
                        do {
                            while !Task.isCancelled {
                                if let id = await avatarQueue.next() {
                                    try Task.checkCancellation()
                                    try await live.requestAvatars(numberIDs: [id])
                                }
                                try await Task.sleep(nanoseconds: 300_000_000)
                            }
                        } catch { live.close() }
                    }
                    let actionLink = ActionLink(live: live)
                    self.actionLinks[entry.id] = actionLink
                    defer {
                        avatarPump.cancel(); live.close()
                        if self.actionLinks[entry.id] === actionLink { self.stopActions(entry.id) }
                    }
                    for try await frame in live.frames {
                        guard !Task.isCancelled, self.foreground, self.generations[entry.id] == generation else { return }
                        let event = try GuestEvent.decode(frame)
                        switch event {
                        case .snapshot(let data, let paused):
                            try self.applySnapshot(data, bundle: currentBundle, entry: entry, paused: paused)
                            actionLink.bundle = currentBundle; actionLink.snapshot = data
                            actionLink.revision = UUID()
                            self.connections[entry.id] = .connected
                            self.syncFailure = nil
                            self.writePreviewStatus()
                            await avatarQueue.replace(self.customAvatarIDs(entry.id))
                            try await live.sendAction(Data(#"{"type":"ble_revokes_req"}"#.utf8))
                            delay = 1
                        case .numbers(let data):
                            // Any policy/list change invalidates pending UI authorization.
                            actionLink.revision = UUID()
                            if actionLink.attempt != nil { live.close(); throw GuestActionSession.Failure.expired }
                            let fresh = try await self.api.bundle(invite: entry.invite, fingerprint: fingerprint)
                            guard !Task.isCancelled, self.generations[entry.id] == generation else { return }
                            bundle = fresh
                            try self.applySnapshot(data, bundle: fresh, entry: entry, paused: nil)
                            actionLink.bundle = fresh; actionLink.snapshot = data
                            await avatarQueue.replace(self.customAvatarIDs(entry.id))
                        case .mode(let paused):
                            if paused { self.bleGuestControl.cancel(guestID: entry.id); self.bleAuthorizedIntent = nil }
                            actionLink.revision = UUID()
                            if paused && actionLink.attempt != nil { live.close(); throw GuestActionSession.Failure.expired }
                            var updated = self.guests
                            if let index = updated.firstIndex(where: { $0.id == entry.id }), updated[index].paused != paused {
                                updated[index].paused = paused
                                try self.save(updated)
                            }
                        case .unavailable(let reason):
                            try self.markUnavailable(entry.id)
                            return
                        case .avatarUnavailable(let numberID):
                            await avatarQueue.received(numberID)
                        case .avatar(let numberID, let envelope):
                            await avatarQueue.received(numberID)
                            guard let metadata = bundle,
                                  let object = self.guests.first(where: { $0.id == entry.id })?.objects.first(where: { $0.numberID == numberID && $0.kind != "ble" }),
                                  object.avatarType == "file",
                                  let bytes = try? GuestObjects.decryptAvatar(bundle: metadata, numberID: numberID, envelope: envelope),
                                  AvatarCache.isImage(bytes) else { continue }
                            let key = AvatarCache.key(guestID: entry.id, objectID: object.id)
                            self.avatars[key] = bytes
                            try? self.avatarCache.save(envelope, key: key)
                        case .bleRevocations(let data):
                            try self.receiveBLERevocations(data, guestID: entry.id)
                        case .message(let cipher):
                            await self.messages.receive(cipher, guestID: entry.id)
                        case .passVouch:
                            if self.passedAccess.contains(where: { $0.parts.contains(where: { $0.sourceID == entry.id }) }) {
                                Task { await self.passManager.reload(sourceID: entry.id) }
                            }
                        case .action(let data):
                            try await self.receiveAction(data, guestID: entry.id, link: actionLink)
                        case .ignore: break
                        }
                    }
                } catch {
                    guard !Task.isCancelled, self.foreground, self.generations[entry.id] == generation else { return }
                    let code = (error as? GuestAPI.Failure)?.code ?? (error is KeychainStore.Failure ? "storage_error" : "connection_failed")
                    self.syncFailure = self.safeDiagnosticCode(code)
                    if code == "storage_error" {
                        self.errorMessage = self.readable(code)
                        self.connections[entry.id] = .offline
                        self.writePreviewStatus()
                        return
                    }
                    if GuestEvent.terminalReasons.contains(code) || code == "network_policy_unsupported" {
                        try? self.markUnavailable(entry.id)
                        return
                    }
                    // A read connection may reconnect; no actions are queued or replayed.
                    bundle = nil
                }
                guard !Task.isCancelled, self.foreground, self.generations[entry.id] == generation else { return }
                self.connections[entry.id] = .offline
                self.writePreviewStatus()
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }

    private func applySnapshot(_ data: Data, bundle: Data, entry: SavedGuest, paused: Bool?) throws {
        let objects = try GuestObjects.decode(bundle: bundle, snapshot: data)
        var updated = guests
        guard let index = updated.firstIndex(where: { $0.id == entry.id }) else { return }
        for old in updated[index].objects where !objects.contains(where: { $0.id == old.id }) {
            let key = AvatarCache.key(guestID: entry.id, objectID: old.id)
            avatars.removeValue(forKey: key)
            avatarCache.remove(key)
        }
        try updateGuestMaterial(&updated[index], objects: objects, bundle: bundle, snapshot: data)
        updated[index].objects = objects
        if let paused { updated[index].paused = paused }
        updated[index].checkedAt = Date()
        try save(updated)
        for object in objects {
            let key = AvatarCache.key(guestID: entry.id, objectID: object.id)
            guard object.avatarType == "file" else {
                avatars.removeValue(forKey: key)
                avatarCache.remove(key)
                continue
            }
            if let cipher = avatarCache.load(key),
               let bytes = try? GuestObjects.decryptAvatar(bundle: bundle, numberID: object.numberID, envelope: cipher),
               AvatarCache.isImage(bytes) { avatars[key] = bytes }
            else { avatars.removeValue(forKey: key); avatarCache.remove(key) }
        }
    }

    private func customAvatarIDs(_ guestID: String) -> [Int] {
        guests.first(where: { $0.id == guestID })?.objects.filter { $0.kind != "ble" && $0.avatarType == "file" }.map(\.numberID) ?? []
    }

    private func safeDiagnosticCode(_ code: String) -> String {
        let allowed = GuestEvent.terminalReasons.union(["connection_failed", "storage_error", "paused", "network_policy_unsupported", "awaiting_owner", "server_error", "replay", "invalid_response", "rate_limited", "too_many_requests", "device_binding_failed", "event_overflow"])
        return allowed.contains(code) ? code : "unknown_error"
    }

    private func readable(_ code: String) -> String {
        switch code {
        case "already_bound", "needs_new_key", "evicted": return "Ключ привязан к другому устройству. Попросите владельца выдать новый."
        case "disabled", "expired", "bad_key", "not_found", "revoked", "auth", "org_key": return "Ключ недоступен. Уточните его состояние у владельца."
        case "storage_error": return "Не удалось сохранить данные в защищённом хранилище."
        case "paused": return "Владелец приостановил действие ключа."
        case "awaiting_owner": return "Ожидаем подготовки ключа владельцем."
        case "network_policy_unsupported": return "У ключа есть сетевые ограничения. Поддержка этих условий ещё не подключена."
        default: return "Не удалось получить данные. Ключ сохранён; попробуйте позже."
        }
    }
}

struct ActionIntent: Identifiable {
    let id = UUID()
    let guestID: String
    let object: GuestObject
    let revision: UUID
    let action: GuestAction
    let wireAction: String
    let policy: GuestActionPolicy
    var title: String { Self.displayTitle(action: action, kind: policy.kind) }
    static func displayTitle(action: GuestAction, kind: String) -> String {
        kind == "ble" ? "Подать импульс / переключить" : action == .close ? "Закрыть" : (action == .toggle ? "Переключить" : "Открыть")
    }
}

private func chosenGuestAction(policy: GuestActionPolicy, numberID: Int, positions: [Int: String]) -> GuestAction {
    policy.kind == "device" && ["open", "opening"].contains(positions[numberID] ?? "") ? .close :
        (policy.toggles && policy.kind == "webhook" ? .toggle : .open)
}

private final class ActionLink {
    let live: GuestActionTransport
    var revision = UUID()
    var bundle: Data?
    var snapshot: Data?
    var hostOnline = false
    var devices: Set<Int> = []
    var positions: [Int: String] = [:]
    var session = GuestActionSession()
    var attempt: (journalID: UUID, numberID: Int, key: String)?
    var timeout: Task<Void, Never>?
    init(live: GuestActionTransport) { self.live = live }
}

extension AppModel {
    func actionIntent(guestID: String, object: GuestObject) -> ActionIntent? {
        guard objectIsVisible(.received(guestID: guestID, objectID: object.id)) else { return nil }
        actionRejections.removeValue(forKey: guestID + "|" + object.id)
        do {
            if object.kind == "ble" {
                guard canManageGuestAccess, !busy, !bleGuestControl.busy,
                      let guest = guests.first(where: { $0.id == guestID }), !guest.paused,
                      guest.objects.contains(object), let cache = guest.bleCache else { throw ActionDenied.message("Защищённый Bluetooth-пропуск не сохранён. Обновите ключ через интернет.") }
                let material = try cache.open(key: guest.invite.bundleKey)
                let decoded = try GuestActionPolicy.decodeBLE(bundle: material.bundle, numberID: object.numberID,
                    epoch: max(cache.maximumEpoch, UInt64(max(0, Date().timeIntervalSince1970))), overrides: guest.automation?[object.id])
                if let reason = decoded.policy.blockedReason { throw ActionDenied.message(reason) }
                let intent = ActionIntent(guestID: guestID, object: object, revision: cache.revision,
                    action: .toggle, wireAction: "toggle", policy: decoded.policy)
                _ = try guestBLEMaterial(intent)
                return intent
            }
            guard foreground, storageReady, !busy,
                  let guest = guests.first(where: { $0.id == guestID }), !guest.paused,
                  guest.objects.contains(object), connection(for: guestID) == .connected,
                  let link = actionLinks[guestID], link.attempt == nil,
                  let bundle = link.bundle, let snapshot = link.snapshot else {
                throw ActionDenied.message("Объект сейчас недоступен. Дождитесь подключения и завершения текущего запроса.")
            }
            let policy = try GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guests.first(where: { $0.id == guestID })?.automation?[object.id])
            if let reason = policy.blockedReason { throw ActionDenied.message(reason) }
            let reachable = policy.serverWebhook || (policy.kind == "device" ? policy.deviceID.map { link.devices.contains($0) } == true : link.hostOnline)
            guard reachable else { throw ActionDenied.message(policy.kind == "device" ? "Контроллер не в сети." : "Телефон владельца не в сети.") }
            let action = chosenGuestAction(policy: policy, numberID: object.numberID, positions: link.positions)
            let wire = action == .close ? "close" : (action == .toggle ? "toggle" : "")
            return ActionIntent(guestID: guestID, object: object, revision: link.revision, action: action, wireAction: wire, policy: policy)
        } catch let ActionDenied.message(text) { rejectAction(guestID: guestID, object: object, message: text) }
        catch BLECommandSession.Failure.expired { rejectAction(guestID: guestID, object: object, message: "Срок Bluetooth-пропуска истёк. Обновите ключ через интернет; продление разрешает владелец.") }
        catch { rejectAction(guestID: guestID, object: object, message: "Не удалось проверить защищённые условия доступа к объекту.") }
        return nil
    }

    func execute(_ intent: ActionIntent) async {
        // Recheck after confirmation/authentication. Never change the direction silently.
        if intent.policy.kind == "ble" {
            defer { finishBLEGuestAuthorization(intent.id) }
            guard let fresh = actionIntent(guestID: intent.guestID, object: intent.object) else { return }
            guard fresh.revision == intent.revision, fresh.policy.template == intent.policy.template else {
                rejectAction(guestID: intent.guestID, object: intent.object, message: "Bluetooth-пропуск изменился. Нажмите на объект ещё раз."); return
            }
            let authenticated = authorizedIntent == intent.id; authorizedIntent = nil
            guard fresh.policy.authentication == nil || authenticated else { rejectAction(guestID: intent.guestID, object: intent.object, message: "Требуется подтверждение личности."); return }
            bleAuthorizedIntent = intent.id
            await bleGuestControl.execute(intent)
            return
        }
        guard let fresh = actionIntent(guestID: intent.guestID, object: intent.object) else { return }
        guard fresh.revision == intent.revision, fresh.action == intent.action, fresh.policy.template == intent.policy.template,
              let link = actionLinks[intent.guestID],
              let guest = guests.first(where: { $0.id == intent.guestID }) else {
            rejectAction(guestID: intent.guestID, object: intent.object, message: "Состояние объекта изменилось. Нажмите на объект ещё раз."); return
        }
        let authenticated = authorizedIntent == intent.id
        authorizedIntent = nil
        guard fresh.policy.authentication == nil || authenticated else { rejectAction(guestID: intent.guestID, object: intent.object, message: "Требуется подтверждение личности."); return }
        let key = intent.guestID + "|" + intent.object.id
        do {
            let frame = try GuestPress.frame(userKey: guest.invite.userKey, host: guest.invite.server,
                                            numberID: intent.object.numberID, wireAction: intent.wireAction)
            try link.session.begin(numberID: intent.object.numberID, action: intent.action,
                                   credential: intent.policy.credential, now: ProcessInfo.processInfo.systemUptime)
            // Persist the attempt BEFORE the first socket write. A crash is ambiguous,
            // so the initial durable result deliberately says no result is known.
            let entry = JournalEntry(who: "Я", what: intent.object.label, actionKey: key,
                                     result: "Результат не получен", level: "warning")
            let previous = journal
            journal.insert(entry, at: 0); journal = Array(journal.prefix(500))
            do { try save(guests) } catch { journal = previous; throw error }
            link.attempt = (entry.id, intent.object.numberID, key)
            actionMessages[key] = "Запрос отправлен"
            link.timeout = Task { [weak self, weak link] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, let link, self.actionLinks[intent.guestID] === link else { return }
                // Reconnect clears uncorrelated legacy responses; never repeat the command.
                link.live.close()
            }
            try await link.live.sendAction(frame)
        } catch {
            stopActions(intent.guestID)
            actionMessages[key] = "Не удалось получить результат команды. Автоматического повтора не будет."
        }
    }

    private func rejectAction(guestID: String, object: GuestObject, message: String) {
        actionRejections[guestID + "|" + object.id] = ActionTapRejection(message: message)
    }

    private enum ActionDenied: Error { case message(String) }

    private func stopActions(_ id: String) {
        guard let link = actionLinks.removeValue(forKey: id) else { return }
        link.timeout?.cancel(); link.live.close()
        if let attempt = link.attempt,
           actionMessages[attempt.key] == "Запрос отправлен" {
            actionMessages[attempt.key] = "Связь завершена. Проверьте результат перед повторным нажатием."
        }
    }

    private func receiveAction(_ data: Data, guestID: String, link: ActionLink) async throws {
        guard let m = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = m["type"] as? String else { return }
        objectWillChange.send()
        switch type {
        case "host_status":
            link.hostOnline = m["online"] as? Bool == true
            if !link.hostOnline { link.revision = UUID() }
        case "devices_online":
            link.devices = Set(m["device_ids"] as? [Int] ?? [])
            link.revision = UUID()
        case "device_online":
            if let id = m["device_id"] as? Int {
                if m["online"] as? Bool == true { link.devices.insert(id) } else { link.devices.remove(id) }
                link.revision = UUID()
            }
        case "obj_state_update":
            if let id = m["num_id"] as? Int {
                link.positions[id] = m["position"] as? String
                link.revision = UUID()
            }
        case "sock_challenge":
            guard let attempt = link.attempt,
                  let guest = guests.first(where: { $0.id == guestID }), !guest.paused,
                  let object = guest.objects.first(where: { $0.kind == "device" && $0.numberID == attempt.numberID }),
                  let bundle = link.bundle, let snapshot = link.snapshot,
                  let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guest.automation?[object.id]),
                  policy.blockedReason == nil,
                  policy.deviceID.map({ link.devices.contains($0) }) == true else { return }
            // Unsolicited, expired and duplicate challenges produce no signature.
            guard let frame = try? link.session.fire(challenge: m, now: ProcessInfo.processInfo.systemUptime) else { return }
            try await link.live.sendAction(frame)
        case "call_status", "device_status", "error":
            guard let attempt = link.attempt, m["other"] as? Bool != true else { return }
            if let id = m["number_id"] as? Int, id > 0, id != attempt.numberID { return }
            var text: String?
            var level = "info"
            if type == "device_status" {
                guard m["number_id"] as? Int == attempt.numberID else { return }
                text = m["message"] as? String
                level = m["level"] as? String ?? "info"
            } else if type == "error" {
                switch m["reason"] as? String {
                case "device_offline": text = "Контроллер не в сети"
                case "host_offline": text = "Телефон владельца не в сети"
                case "rate_limit", "rate_limited": text = "Слишком много запросов. Подождите перед повторным нажатием."
                default: text = "Запрос отклонён"
                }
                level = "danger"
            }
            else {
                switch m["status"] as? String {
                case "declined": text = "Запрос отклонён владельцем"; level = "danger"
                case "busy": text = "Владелец занят"; level = "warning"
                case "dialing", "accepted", "ok": text = "Набираем…"; level = "success"
                case "awaiting_confirm", "sent_to_host": text = "Ожидание подтверждения…"
                case "phone_handoff": text = "Владелец передал звонок в приложение «Телефон»"
                case "error", "host_offline", "device_offline": text = "Ошибка вызова"; level = "danger"
                default: break
                }
            }
            guard let text, !text.isEmpty, text.utf8.count <= 4096 else { return }
            actionMessages[attempt.key] = text
            // Clearing history must neither hide the live result nor recreate a row.
            guard let index = journal.firstIndex(where: { $0.id == attempt.journalID }) else { return }
            let previous = journal
            journal[index].result = text; journal[index].level = level
            do { try save(guests) } catch { journal = previous; throw error }
        default: break
        }
    }
}

extension AppModel {
    func setActionCode(_ code: String) async throws {
        guard !authenticationBusy else { throw KeychainStore.Failure(status: -1) }
        authenticationBusy = true
        defer { authenticationBusy = false }
        guard actionCode == nil, foreground else { throw KeychainStore.Failure(status: -1) }
        let salt = GuestCrypto.randomBytes(count: 16)
        let verifier = try await Task.detached { try LocalActionCode.derive(code, salt: salt) }.value
        guard foreground, actionCode == nil else { throw KeychainStore.Failure(status: -1) }
        actionCode = LocalActionCode(salt: salt, verifier: verifier)
        do { try save(guests) } catch { actionCode = nil; throw error }
        // Enrollment is optional; a failure must not roll back the persisted PIN.
        try? ActionBiometrics.enroll(service: biometricService)
    }
    func authorizeCode(_ code: String, intent: ActionIntent) async throws -> Bool {
        try await authorizeCode(code, authentication: intent.policy.authentication, requestID: intent.id)
    }
    private func authorizeCode(_ code: String, authentication: String?, requestID: UUID?) async throws -> Bool {
        guard !authenticationBusy else { return false }
        authenticationBusy = true
        defer { authenticationBusy = false }
        guard var saved = actionCode, foreground, saved.lockedUntil <= Date(),
              authentication != "biometric" else { return false }
        let candidate = try await Task.detached { try LocalActionCode.derive(code, salt: saved.salt) }.value
        guard foreground else { return false }
        let accepted = saved.matches(candidate)
        if accepted { saved.failures = 0; saved.lockedUntil = .distantPast } else { saved.failed() }
        let previous = actionCode; actionCode = saved
        do { try save(guests) } catch { actionCode = previous; throw error }
        if accepted { authorizedIntent = requestID }
        return accepted
    }
    func authorizeBiometric(_ intent: ActionIntent) async throws {
        try await authorizeBiometric(authentication: intent.policy.authentication, requestID: intent.id)
    }
    private func authorizeBiometric(authentication: String?, requestID: UUID?) async throws {
        guard !authenticationBusy else { throw KeychainStore.Failure(status: -1) }
        authenticationBusy = true
        defer { authenticationBusy = false }
        guard actionCode != nil, foreground, authentication != "pin" else { throw KeychainStore.Failure(status: -1) }
        let service = biometricService
        try await Task.detached { try ActionBiometrics.authenticate(service: service) }.value
        guard foreground else { throw KeychainStore.Failure(status: -1) }
        authorizedIntent = requestID
    }
}

#if DEBUG
extension AppModel {
    /// Isolated protocol integration tests supply a recording controller, never a real invite.
    func attachTestController(_ transport: GuestActionTransport, guestID: String, bundle: Data, snapshot: Data) throws {
        guard let guest = guests.first(where: { $0.id == guestID }) else { throw KeychainStore.Failure(status: -1) }
        try applySnapshot(snapshot, bundle: bundle, entry: guest, paused: false)
        let link = ActionLink(live: transport)
        link.bundle = bundle; link.snapshot = snapshot
        actionLinks[guestID] = link; connections[guestID] = .connected
    }
    func receiveTestController(_ data: Data, guestID: String) async throws {
        guard let link = actionLinks[guestID] else { return }
        try await receiveAction(data, guestID: guestID, link: link)
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
extension AppModel {
    /// Only the isolated capture model calls this; refuses actual server identities.
    func installCaptureGuest(_ guest: SavedGuest) throws {
        guard guest.invite.server == "controller.invalid", guests.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        try save([guest])
    }
}
#endif

extension AppModel {
    private func rejectOwnerAction(_ id: UUID, _ message: String) {
        ownerActionRejections[id] = ActionTapRejection(message: message)
    }
    func ownerActionIntent(server: String, objectID: UUID) -> OwnerActionIntent? {
        ownerActionRejections.removeValue(forKey: objectID)
        do {
            guard foreground, canManageGuestAccess, !busy, !ownerBusy,
                  let owner = owners.first(where: { $0.server == server }), !owner.registrationPending,
                  let object = owner.objects?.first(where: { $0.id == objectID }), object.ownerCardAvailable else {
                throw ActionDenied.message("Объект сейчас недоступен.")
            }
            let policy = try OwnerManualPolicy(object.localPolicy)
            if let reason = policy.blockedReason { throw ActionDenied.message(reason) }
            if object.kind == "ble" {
                guard !bleControl.busy else { throw ActionDenied.message("Предыдущая Bluetooth-команда ещё не завершена.") }
            } else if object.kind == "webhook" && object.routing["webhook_mode"] == "phone" {
                guard ownerControl.phoneWebhookReady(server: server, objectID: objectID) else {
                    throw ActionDenied.message("Предыдущий запрос ещё не завершён.")
                }
            } else if object.kind != "call" {
                guard ownerControl.readyForTap(server: server) else { throw ActionDenied.message("Нет готового соединения или предыдущий запрос ещё не завершён.") }
                if object.kind == "device" {
                    guard object.wrappedSocketSecret != nil else { throw ActionDenied.message("Контроллеру нужна защищённая настройка перед открытием.") }
                    guard let device = object.routing["device_id_ref"].flatMap(Int.init),
                          ownerControl.onlineDevices[server]?.contains(device) == true else {
                        throw ActionDenied.message("Контроллер не в сети.")
                    }
                }
            }
            let metadata = try object.metadata(masterKey: owner.masterKey)
            let position = object.numberID.flatMap { ownerControl.positions[server]?[$0] }
            let action: GuestAction = object.kind == "ble" ? .toggle :
                (object.kind == "device" && ["open", "opening"].contains(position ?? "") ? .close :
                (object.kind == "webhook" && metadata["wh_toggle"] as? Int == 1 ? .toggle : .open))
            return OwnerActionIntent(server: server, object: object, label: metadata["label"] as? String ?? "Объект", action: action, policy: policy)
        } catch let ActionDenied.message(message) { rejectOwnerAction(objectID, message) }
        catch { rejectOwnerAction(objectID, "Не удалось проверить защищённые данные объекта.") }
        return nil
    }
    private func ownerIntentStillValid(_ intent: OwnerActionIntent) -> Bool {
        guard ProcessInfo.processInfo.systemUptime - intent.created < 120,
              let fresh = ownerActionIntent(server: intent.server, objectID: intent.object.id),
              fresh.object == intent.object, fresh.action == intent.action else { return false }
        return true
    }
    func authorizeCode(_ code: String, ownerIntent: OwnerActionIntent) async throws -> Bool {
        guard ownerIntentStillValid(ownerIntent) else { return false }
        return try await authorizeCode(code, authentication: ownerIntent.policy.authentication, requestID: ownerIntent.id)
    }
    func authorizeBiometric(_ intent: OwnerActionIntent) async throws {
        guard ownerIntentStillValid(intent) else { throw KeychainStore.Failure(status: -1) }
        try await authorizeBiometric(authentication: intent.policy.authentication, requestID: intent.id)
    }
    func execute(_ intent: OwnerActionIntent) async {
        let authenticated = authorizedIntent == intent.id
        authorizedIntent = nil
        guard activeOwnerAction == nil, ownerIntentStillValid(intent) else {
            rejectOwnerAction(intent.object.id, "Состояние объекта изменилось. Нажмите на объект ещё раз."); return
        }
        guard intent.policy.authentication == nil || authenticated else {
            rejectOwnerAction(intent.object.id, "Требуется подтверждение личности."); return
        }
        activeOwnerAction = intent
        defer { activeOwnerAction = nil }
        if intent.object.kind == "ble" { await bleControl.execute(server: intent.server, objectID: intent.object.id) }
        else if intent.object.kind == "call" { await ownerControl.dial(server: intent.server, objectID: intent.object.id) }
        else if intent.object.kind == "webhook" && intent.object.routing["webhook_mode"] == "phone" {
            await ownerControl.phoneWebhook(server: intent.server, objectID: intent.object.id, action: intent.action)
        } else { await ownerControl.execute(server: intent.server, objectID: intent.object.id, action: intent.action) }
    }
}

#if DEBUG && targetEnvironment(simulator)
extension AppModel {
    func setCaptureOwnerConfirmation(_ objectID: UUID) throws {
        guard owners.count == 1, owners[0].server == "controller.invalid",
              let index = owners[0].objects?.firstIndex(where: { $0.id == objectID }) else { throw GuestCrypto.Failure.invalidEnvelope }
        var updated = owners
        updated[0].objects![index].localPolicy = Data(#"{"confirm_on":true}"#.utf8)
        try saveOwners(updated)
    }
}
#endif

extension AppModel {
    func importDelegatedJournal(_ events: [DelegatedJournalEvent], sourceID: String) throws {
        guard canManageGuestAccess, let source = guests.first(where: { $0.id == sourceID }) else { throw BackupFailure.noAccess }
        let previousJournal = journal, previousLedger = delegatedJournalLedger
        do {
            let fresh = try delegatedJournalLedger.accept(events, server: source.invite.server)
            guard !fresh.isEmpty else { return }
            for event in fresh {
                let name = passedAccess.first(where: { $0.server == source.invite.server && $0.group == event.group })?.label ?? "Переданный ключ"
                let label = source.objects.first(where: { $0.numberID == event.numberID && $0.kind != "ble" })?.label ?? "#\(event.numberID)"
                journal.append(JournalEntry(who: "Гость: " + name, what: label,
                    actionKey: "delegated:" + source.invite.server + ":" + String(event.id),
                    date: Date(timeIntervalSince1970: TimeInterval(event.epoch))))
            }
            journal.sort { $0.date > $1.date }; journal = Array(journal.prefix(500))
            try save(guests)
        } catch {
            journal = previousJournal; delegatedJournalLedger = previousLedger; throw error
        }
    }
}

extension AppModel {
    func saveOwnerActionPolicy(server: String, objectID: UUID, expected: Data?, confirmation: Bool, authentication: String) -> Bool {
        guard canManageGuestAccess, !ownerBusy, !busy,
              ["none", "pin", "biometric", "either"].contains(authentication),
              let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID }),
              let object = owners[index].objects?[offset], object.pending == nil,
              object.available != false, object.localPolicy == expected else { return false }
        do {
            _ = try OwnerManualPolicy(object.localPolicy)
            var policy: [String: Any] = [:]
            if let bytes = object.localPolicy {
                guard let decoded = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                policy = decoded
            }
            policy["confirm_on"] = confirmation; policy["confirm"] = confirmation
            policy["auth_on"] = authentication != "none"
            if authentication != "none" { policy["auth"] = authentication }
            let bytes = try JSONSerialization.data(withJSONObject: policy, options: .sortedKeys)
            _ = try OwnerManualPolicy(bytes)
            var updated = owners; updated[index].objects![offset].localPolicy = bytes
            try saveOwners(updated)
            ownerActionRejections.removeValue(forKey: objectID)
            ownerObjectMessages.removeValue(forKey: objectID)
            return true
        } catch { ownerObjectMessages[objectID] = "Не удалось сохранить защиту объекта. Прежние правила сохранены."; return false }
    }
}

extension AppModel {
    func entryDidBackground(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        entryLockPolicy.background(now: now)
    }
    func entryRequiresUnlock(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        entryLockPolicy.requiresUnlock(enabled: appLockEnabled, hasCode: hasActionCode, now: now)
    }
    func checkEntryLock(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        appLocked = entryRequiresUnlock(now: now)
        if appLocked { authorizedIntent = nil }
    }
    func unlockApplication(code: String) async throws -> Bool {
        guard appLocked else { return true }
        guard try await authorizeCode(code, authentication: "pin", requestID: nil) else { return false }
        entryLockPolicy.unlocked(); appLocked = false
        return true
    }
    func unlockApplicationWithBiometrics() async throws {
        guard appLocked, appEntryBiometricEnabled else { throw KeychainStore.Failure(status: -1) }
        try await authorizeBiometric(authentication: "biometric", requestID: nil)
        entryLockPolicy.unlocked(); appLocked = false
    }
    func configureEntryLock(enabled: Bool, biometric: Bool, code: String) async throws -> Bool {
        guard !appLocked, foreground, storageReady, hasActionCode else { return false }
        let requiresCode = (appLockEnabled && !enabled) || (!appEntryBiometricEnabled && biometric)
        if requiresCode {
            guard try await authorizeCode(code, authentication: "pin", requestID: nil) else { return false }
        }
        if biometric && !appEntryBiometricEnabled {
            guard ActionBiometrics.available else { throw KeychainStore.Failure(status: -1) }
            try ActionBiometrics.enroll(service: biometricService)
        }
        guard foreground, !appLocked else { return false }
        let previousEnabled = appLockEnabled, previousBio = appEntryBiometricEnabled
        appLockEnabled = enabled; appEntryBiometricEnabled = biometric
        do { try save(guests) }
        catch { appLockEnabled = previousEnabled; appEntryBiometricEnabled = previousBio; throw error }
        entryLockPolicy.unlocked()
        return true
    }
    func changeActionCode(current: String, replacement: String) async throws -> Bool {
        guard !appLocked, foreground, try await authorizeCode(current, authentication: "pin", requestID: nil),
              let saved = actionCode, !authenticationBusy else { return false }
        authenticationBusy = true
        defer { authenticationBusy = false }
        let salt = GuestCrypto.randomBytes(count: 16)
        let verifier = try await Task.detached { try LocalActionCode.derive(replacement, salt: salt) }.value
        guard foreground, actionCode?.salt == saved.salt, actionCode?.verifier == saved.verifier else { return false }
        actionCode = LocalActionCode(salt: salt, verifier: verifier)
        do { try save(guests) } catch { actionCode = saved; throw error }
        authorizedIntent = nil
        return true
    }
}


extension AppModel {
    /// Observational presentation state only. It never authorizes a command.
    func noteBLESighting(_ target: ObjectReference, sleepSeconds: UInt8? = nil) {
        let window = sleepSeconds.map { min(60, max(5, Int($0) * 5 + 5)) } ?? 60
        bleVisibleUntil[target] = ProcessInfo.processInfo.systemUptime + TimeInterval(window)
    }
    func objectAvailability(_ entry: CatalogObject, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CatalogAvailability {
        if entry.kind == "webhook" { return .neutral }
        if case let .received(guest, _) = entry, guest.paused { return .offline }
        if entry.kind == "ble" {
            if case let .received(guest, object) = entry {
                guard let cache = guest.bleCache, let material = try? cache.open(key: guest.invite.bundleKey),
                      (try? GuestActionPolicy.decodeBLE(bundle: material.bundle, numberID: object.numberID,
                        epoch: max(cache.maximumEpoch, UInt64(max(0, Date().timeIntervalSince1970))), overrides: guest.automation?[object.id])) != nil else { return .offline }
            }
            guard let until = bleVisibleUntil[entry.target] else { return .unknown }
            return now < until ? .ready : .offline
        }
        switch entry {
        case let .owned(owner, object):
            if object.kind == "call" { return .ready }
            guard ownerControl.connections[owner.server] == .connected else {
                return ownerControl.connections[owner.server] == .connecting ? .connecting : .offline
            }
            guard let id = object.routing["device_id_ref"].flatMap(Int.init) else { return .unknown }
            return ownerControl.onlineDevices[owner.server]?.contains(id) == true ? .ready : .offline
        case let .received(guest, object):
            switch connection(for: guest.id) {
            case .connecting: return .connecting
            case .offline, .unavailable: return .offline
            case .connected: break
            }
            guard let link = actionLinks[guest.id], let bundle = link.bundle, let snapshot = link.snapshot,
                  let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guest.automation?[object.id]) else { return .unknown }
            if policy.kind == "device" { return policy.deviceID.map { link.devices.contains($0) } == true ? .ready : .offline }
            return link.hostOnline ? .ready : .offline
        }
    }
}

extension AppModel {
    /// Android's editor saves rule changes locally as they are made. Network
    /// publication is a separate durable queue, scoped to the issued key.
    @discardableResult
    func saveAutomation(_ context: AutomationSettingsContext, template: AutomationTemplate, allowStream: Bool? = nil) -> Bool {
        guard canManageGuestAccess, !busy, pendingRestore == nil, context.canEdit else { return false }
        do {
            let current = try automationContext(context.destination)
            guard current.canEdit, try current.template.data() == context.template.data() else { throw GuestCrypto.Failure.invalidEnvelope }
            let bytes = try template.data()
            switch context.destination {
            case .draft: return false
            case .object(.owned(let server, let id)):
                guard let index = owners.firstIndex(where: { $0.server == server }),
                      let offset = owners[index].objects?.firstIndex(where: { $0.id == id }) else { return false }
                _ = try OwnerManualPolicy(bytes)
                var updated = owners; updated[index].objects![offset].localPolicy = bytes
                if let number = updated[index].objects![offset].numberID { updated[index].queueObjectSettings(numberID: number) }
                try saveOwners(updated)
                ownerObjectMessages.removeValue(forKey: id); ownerActionRejections.removeValue(forKey: id)
            case .object(.received(let guestID, let objectID)):
                guard let index = guests.firstIndex(where: { $0.id == guestID }) else { return false }
                var updated = guests
                var record = updated[index].automation?[objectID] ?? IncomingAutomationConfiguration(owner: AutomationTemplate())
                try record.edit(template)
                var values = updated[index].automation ?? [:]; values[objectID] = record
                updated[index].automation = values
                try save(updated)
                authorizedIntent = nil; bleAuthorizedIntent = nil
                bleGuestControl.cancel(guestID: guestID)
                if actionLinks[guestID]?.attempt != nil { stopActions(guestID) }
                else { actionLinks[guestID]?.revision = UUID() }
            case .issued(let server, let keyID, let objectID):
                guard let index = owners.firstIndex(where: { $0.server == server }),
                      let offset = owners[index].issuedKeys?.firstIndex(where: { $0.id == keyID }),
                      let object = owners[index].objects?.first(where: { $0.id == objectID }), let number = object.numberID else { return false }
                var updated = owners
                let masterKey = updated[index].masterKey
                try updated[index].issuedKeys![offset].configureObjectSettings(numberID: number, template: template,
                    allowStream: allowStream ?? current.allowStream, masterKey: masterKey)
                updated[index].queueKeySettings(keyID)
                try saveOwners(updated)
            }
            return true
        } catch {
            errorMessage = "Не удалось сохранить автонастройки. Прежние правила сохранены; откройте актуальные настройки объекта."
            return false
        }
    }
}

extension AppModel {
    func ownerDeviceCredentials(server: String, objectID: UUID) throws -> DeviceConfigurationCredentials? {
        guard canManageGuestAccess, let owner = owners.first(where: { $0.server == server }),
              let object = owner.objects?.first(where: { $0.id == objectID }) else { throw GuestCrypto.Failure.invalidEnvelope }
        return try object.deviceCredentials(masterKey: owner.masterKey)
    }
    func ownerSocketBindingCode(server: String, objectID: UUID) throws -> String {
        guard canManageGuestAccess, !busy, !ownerBusy,
              let index = owners.firstIndex(where: { $0.server == server }),
              let offset = owners[index].objects?.firstIndex(where: { $0.id == objectID && $0.pending == nil && $0.available != false }) else { throw GuestCrypto.Failure.invalidEnvelope }
        var updated = owners
        let masterKey = updated[index].masterKey
        let code = try updated[index].objects![offset].prepareSocketBinding(masterKey: masterKey)
        if let number = updated[index].objects![offset].numberID { updated[index].queueObjectSettings(numberID: number) }
        try saveOwners(updated)
        return code
    }
}

extension AppModel {
    func avatarPreset(_ target: ObjectReference) -> Int? {
        if case .received = target, let preset = objectPreferences.presentation(for: target).avatarPreset { return preset }
        guard let entry = catalogObject(target) else { return nil }
        let value: String?
        switch entry {
        case let .owned(owner, object): value = try? object.metadata(masterKey: owner.masterKey)["avatar_type"] as? String
        case let .received(_, object): value = object.avatarType
        }
        guard let value, value.hasPrefix("preset:"), let index = Int(value.dropFirst(7)), (0...7).contains(index) else { return nil }
        return index
    }
    func localAvatar(_ target: ObjectReference) -> Data? {
        try? objectPreferences.avatar(target, localKey: identity)
    }
    func saveObjectAvatar(_ target: ObjectReference, preset: Int?, jpeg: Data?) async -> Bool {
        guard canManageGuestAccess, !busy, !ownerBusy, catalogObject(target) != nil,
              jpeg.map(AvatarCache.isImage) ?? true else { return false }
        do {
            switch target {
            case .received:
                var preferences = objectPreferences
                try preferences.setAvatar(target, preset: preset, jpeg: jpeg, localKey: identity)
                try save(guests, preferences: preferences)
                return true
            case let .owned(server, id):
                guard let index = owners.firstIndex(where: { $0.server == server }),
                      let offset = owners[index].objects?.firstIndex(where: { $0.id == id }) else { return false }
                ownerBusy = true; defer { ownerBusy = false }
                var updated = owners
                let master = updated[index].masterKey
                try updated[index].objects![offset].updateAvatar(preset: preset, jpeg: jpeg, masterKey: master)
                if let number = updated[index].objects![offset].numberID { updated[index].queueObjectSettings(numberID: number) }
                try saveOwners(updated)
                return await sendOwnerObject(server: server, objectID: id)
            }
        } catch {
            errorMessage = "Не удалось сохранить иконку объекта. Прежняя иконка сохранена."
            return false
        }
    }
}

extension AppModel {
    @discardableResult func saveIssuedLifetime(server: String, keyID: UUID, objectID: UUID, seconds: UInt32) -> Bool {
        guard canManageGuestAccess, let i = owners.firstIndex(where: { $0.server == server }),
              let j = owners[i].issuedKeys?.firstIndex(where: { $0.id == keyID }),
              let object = owners[i].objects?.first(where: { $0.id == objectID && $0.kind == "ble" }), let number = object.numberID else { return false }
        do {
            var updated = owners
            try updated[i].issuedKeys![j].configureLifetime(numberID: number, seconds: seconds)
            try saveOwners(updated); return true
        } catch { errorMessage = "Не удалось сохранить срок действия. Текущий пропуск не изменён."; return false }
    }
    @discardableResult func saveIssuedCallPreference(server: String, keyID: UUID, objectID: UUID, preference: OwnerCallPreference) -> Bool {
        guard canManageGuestAccess, let i = owners.firstIndex(where: { $0.server == server }),
              let j = owners[i].issuedKeys?.firstIndex(where: { $0.id == keyID }),
              let object = owners[i].objects?.first(where: { $0.id == objectID && $0.kind == "call" }), let number = object.numberID else { return false }
        do {
            var updated = owners
            try updated[i].issuedKeys![j].configureCall(numberID: number, preference: preference)
            try saveOwners(updated); return true
        } catch { errorMessage = "Не удалось сохранить реакцию на вызов. Прежние настройки сохранены."; return false }
    }
}


extension AppModel {
    func beginEditingGuestKey(_ id: UUID) { editingOwnerKeys.insert(id) }
    func endEditingGuestKey(_ id: UUID) { editingOwnerKeys.remove(id); scheduleOwnerSettingsRefresh() }
}
