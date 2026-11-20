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
    @Published private(set) var selectedOwnerServer = "entrixy.com"
    @Published private(set) var networkPrivacy = try! NetworkPrivacyPreferences()
    @Published var networkPrivacyPrompt: PrivacyNetwork?
    @Published var diagnosticConsentPrompt = false
    @Published var keyAcceptance: KeyAcceptance?
    @Published var incomingMessagePromptID: String?
    lazy var diagnostics = AppDiagnostics(app:self)
    lazy var remoteNotifications = AppRemoteNotifications(app:self)
    @Published private(set) var localTaskDialogs = Set<UUID>()
    func setLocalTaskDialog(_ id: UUID, presented: Bool) {
        guard localTaskDialogs.contains(id) != presented else { return }
        if presented { localTaskDialogs.insert(id) } else { localTaskDialogs.remove(id) }
    }
    var hasTaskDialog: Bool { hasRootDialog || !localTaskDialogs.isEmpty }
    var hasRootDialog: Bool {
        hasInlineRootDialog || diagnosticConsentPrompt || incomingMessagePromptID != nil
    }
    /// UIKit presented controllers own their accessibility modal boundary. Do
    /// Keep the initial NavigationStack's provider attached; the presented host
    /// determines which accessibility tree is exposed to avoid double hiding.
    /// Hit testing and action authority still use ALL root/task dialogs.
    var hasInlineRootDialog: Bool {
        actionPrompt != nil || bleInformationTarget != nil || objectRemovalTarget != nil || objectAvatarTarget != nil
        || ownerGuestRequestPending || companyRequestID != nil || guestRemovalTarget != nil || codePrompt != nil
        || backupPromptPending || serverPrompt != nil || networkPrivacyPrompt != nil || keyAcceptance != nil
    }
    let privacyRouter: ServerPrivacyRouter?
    private var unsavedGuestNetworkRestrictions = Set<String>()
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
    @Published var bleInformationTarget: ObjectReference?
    @Published var bleInformation: [ObjectReference: BLEDeviceInformation] = [:]
    @Published var ownerGuestRequestPending = false
    lazy var automationSensors = AutomationSensors()
    lazy var phoneReadiness = PhoneReadiness()
    lazy var automation = AutomationCoordinator(app: self)
    var automaticPermits: [ObjectReference: AutomationReadiness] = [:]
    var automaticConsumedAt: [ObjectReference: Date] = [:]
    @Published private(set) var ownerGuestDefaults = OwnerGuestDefaults()
    @Published private(set) var companies: [KnownCompany] = []
    private var androidArchives: [AndroidBackupDocument] = []
    @Published private(set) var androidPendingGuests: [AndroidGuestMigration] = []
    @Published private(set) var companyBusy = false
    @Published var companyRequestID: String?
    @Published var companyGrantRequest: String?
    @Published var guestRemovalTarget: GuestRemovalTarget?
    @Published var codePrompt: AppCodePrompt?
    @Published var actionPrompt: ActionPrompt?
    private var executingActionPrompt: ActionPrompt?
    private var confirmedAutomaticPromptID: UUID?
    func dismissActionPrompt(_ id: UUID) {
        guard let prompt = actionPrompt, prompt.id == id else { return }
        actionPrompt = nil
        if prompt.automatic { automaticPermits.removeValue(forKey:prompt.target) }
        if authorizedIntent == id { authorizedIntent = nil }
    }
    func actionPromptRetainsAutomaticEvidence(_ target: ObjectReference) -> Bool {
        [actionPrompt,executingActionPrompt].contains { $0?.automatic == true && $0?.target == target }
    }
    func executeActionPrompt(_ request: ActionPrompt) async {
        guard canManageGuestAccess, actionPrompt?.id == request.id, executingActionPrompt == nil else { return }
        // Consume the actual presented request before dispatch. A second tap or
        // delayed callback cannot reuse it, even after a successful response.
        actionPrompt = nil; executingActionPrompt = request
        confirmedAutomaticPromptID = request.automatic ? request.id : nil
        defer {
            // A background/resume boundary may have replaced this execution.
            // Its late completion cannot clear a newer prompt's proof/state.
            if executingActionPrompt?.id == request.id {
                confirmedAutomaticPromptID = nil; executingActionPrompt = nil
                if request.automatic { automaticPermits.removeValue(forKey:request.target) }
            }
        }
        switch request { case .guest(let intent): await execute(intent); case .owner(let intent): await execute(intent) }
    }
    private func consumeAutomaticPromptConfirmation(_ id: UUID) -> Bool {
        guard confirmedAutomaticPromptID == id else { return false }
        confirmedAutomaticPromptID = nil; return true
    }
    @Published var backupPromptPending = false
    @Published var serverPrompt: ServerSettingsPrompt?
    @Published var settingsRequest: SettingsTab?
    @Published private(set) var bleAutomationDisarmed = Set<String>()
    @Published private(set) var cameraActivity: [ObjectReference: UInt64] = [:]
    func noteCameraAction(_ target: ObjectReference) { cameraActivity[target] = (cameraActivity[target] ?? 0) &+ 1 }
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
    lazy var backupPresentation = BackupPresentation(app:self,manager:backups)
    lazy var delegationInbox = DelegationInbox(app: self)
    lazy var passManager = PassManager(app: self)
    private lazy var bleTransport = CoreBluetoothTransport()
    lazy var blePairing = BLEPairingModel(app: self, transport: bleTransport)
    lazy var bleGuestControl = BLEGuestControlModel(app: self, transport: bleTransport)
    private var bleAuthorizedIntent: UUID?
    private var bleAuthorizedAutomaticTarget: ObjectReference?
    lazy var bleControl = BLEOwnerControlModel(app: self, transport: bleTransport)
    lazy var messages = MessageManager(app: self)
    lazy var promotions = AppPromotions(app:self)
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
    var isForeground: Bool { foreground }
    var storageAllowsAutomation: Bool { storageReady && pendingRestore == nil }
    var backgroundMonitoring = false
    var backgroundActionScope: BackgroundActionScope?
    private var resumeRequested = false
    private var syncFailure: String?

    init(storage: StateStorage = KeychainStore(), ownerAPI: OwnerTransport = OwnerAPI(),privacyRouter: ServerPrivacyRouter? = nil) {
        self.storage = storage
        self.privacyRouter = privacyRouter
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
            if let privacy = state.networkPrivacy { networkPrivacy = privacy }
            for owner in owners where owner.privacyNetworks != nil {
                networkPrivacy = try networkPrivacy.merging(NetworkPrivacyPreferences(own:owner.privacyNetworks!))
            }
            try networkPrivacy.validate()
            selectedOwnerServer = try GuestInvite.normalizeServer(state.selectedOwnerServer ?? owners.first?.server ?? "entrixy.com")
            ownerGuestDefaults = state.ownerGuestDefaults ?? OwnerGuestDefaults()
            companies = state.companies ?? []
            androidArchives = state.androidArchives ?? []
            androidPendingGuests = state.androidPendingGuests ?? []
            guard androidPendingGuests.count <= 1000, Set(androidPendingGuests.map(\.id)).count == androidPendingGuests.count,
                  Set(androidPendingGuests.map(\.id)).isDisjoint(with:Set(state.guests.map(\.id))) else { throw BackupFailure.invalidPayload }
            for source in androidPendingGuests { try source.validate() }
            try AndroidBackupDocument.validateArchives(androidArchives)
            try KnownCompany.validateDirectory(companies)
            try ownerGuestDefaults.validate()
            let preferences = state.objectPreferences ?? ObjectCatalogPreferences()
            try preferences.validate()
            objectPreferences = preferences
            bleAutomationDisarmed = state.bleAutomationDisarmed ?? []
            guard bleAutomationDisarmed.count <= 2000, bleAutomationDisarmed.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw KeychainStore.Failure(status:-1) }
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
            for index in guests.indices where guests[index].privacyNetworks == nil {
                if let cached = try guests[index].bleCache?.open(key:guests[index].invite.bundleKey),
                   let bundle = try JSONSerialization.jsonObject(with:cached.bundle) as? [String:Any] {
                    guests[index].privacyNetworks = try PrivacyNetwork.decode(bundle["net_block"])
                }
            }
            journal = (state.journal ?? []).filter(\.isAction)
            storageReady = true
        } catch {
            startupStatus = (error as? KeychainStore.Failure)?.status ?? -1
            errorMessage = "Не удалось прочитать защищённое хранилище. Повторно откройте приложение после разблокировки iPhone."
        }
        writePreviewStatus(status: startupStatus)
        syncNetworkPrivacyRouting()
    }

    private func syncNetworkPrivacyRouting() {
        guard let privacyRouter else { return }
        func restricted(_ guest: SavedGuest) -> Bool {
            if let networks = guest.privacyNetworks { return !networks.isEmpty }
            do {
                guard let cached = try guest.bleCache?.open(key:guest.invite.bundleKey) else { return false }
                guard let b = try JSONSerialization.jsonObject(with:cached.bundle) as? [String:Any] else { return true }
                return try !PrivacyNetwork.decode(b["net_block"]).isEmpty
            } catch { return true }
        }
        let payload = pendingRestore?.payload
        let blocked = !storageReady || !unsavedGuestNetworkRestrictions.isEmpty || !networkPrivacy.own.isEmpty
            || owners.contains { !($0.privacyNetworks ?? []).isEmpty }
            || guests.contains(where:restricted)
            || androidPendingGuests.contains { !($0.privacyNetworks ?? []).isEmpty }
            || !(payload?.networkPrivacy?.own ?? []).isEmpty
            || (payload?.owners ?? []).contains { !($0.privacyNetworks ?? []).isEmpty }
            || (payload?.guests ?? []).contains(where:restricted)
            || (payload?.androidGuests ?? []).contains { !($0.privacyNetworks ?? []).isEmpty }
        privacyRouter.update(restricted:blocked,cellularAuthorized:storageReady && networkPrivacy.cellularAuthorized,forcedClosed:!storageReady)
    }

    private func rememberGuestNetworkRestrictions(bundle: Data,id: String) throws {
        guard let content = try JSONSerialization.jsonObject(with:bundle) as? [String:Any],
              let index = guests.firstIndex(where:{ $0.id == id }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let networks = try PrivacyNetwork.decode(content["net_block"])
        guard guests[index].privacyNetworks != networks else { return }
        // Tighten the live route before persistence. A failed write keeps this
        // restriction in force even if another unrelated save later succeeds.
        if !networks.isEmpty { unsavedGuestNetworkRestrictions.insert(id); syncNetworkPrivacyRouting() }
        var updated = guests; updated[index].privacyNetworks = networks
        try save(updated)
        unsavedGuestNetworkRestrictions.remove(id); syncNetworkPrivacyRouting()
    }

    func prepareServerRouting() async -> Bool { if let privacyRouter { return await privacyRouter.start() }; return true }
    func diagnosticFacts() -> DiagnosticFacts {
        DiagnosticFacts(owners:owners.count,guests:guests.count,
            objects:guests.reduce(0) { $0+$1.objects.count } + owners.reduce(0) { $0+($1.objects?.count ?? 0) },
            pending:androidPendingGuests.count+delegations.count+(pendingRestore == nil ? 0 : 1),
            connected:connections.values.filter { $0 == .connected }.count,storageReady:storageReady,privacyBlocked:privacyRouter?.route == .blocked)
    }
    func phoneRequirements() -> PhoneRequirements {
        var needs = PhoneRequirements()
        for entry in controlObjects {
            switch entry {
            case .owned(let owner,_): if owner.ownershipLost == true { continue }
            case .received(let guest,_): if guest.paused { continue }
            }
            if let context = try? automationContext(.object(entry.target)) {
                let location = context.template.geoEnabled || (context.template.wifiEnabled && context.template.wifiMode == "connect")
                needs.location = needs.location || location; needs.preciseLocation = needs.preciseLocation || location
                needs.bluetooth = needs.bluetooth || context.isBLE
            }
        }
        needs.notifications = owners.contains { owner in
            owner.ownershipLost != true && (owner.issuedKeys ?? []).contains { key in
                key.state != .revoked && key.state != .paused && (key.callPreferences ?? [:]).values.contains { $0.reaction == "notify" }
            }
        }
        needs.backgroundLocation = needs.location && controlObjects.contains { entry in
            (try? automationContext(.object(entry.target)).template.geoEnabled) == true
        }
        needs.notifications = needs.notifications || controlObjects.contains { entry in
            guard let t = try? automationContext(.object(entry.target)).template else { return false }
            return t.geoEnabled || t.bleEnabled
        }
        return needs
    }

    @discardableResult func setNetworkPrivacy(_ preferences: NetworkPrivacyPreferences) -> Bool {
        guard canManageGuestAccess, !busy, !ownerBusy else { return false }
        let previous = networkPrivacy
        do {
            try preferences.validate()
            var updated = owners
            if preferences.own != previous.own {
                for index in updated.indices { try updated[index].setPrivacyNetworks(preferences.own) }
            }
            networkPrivacy = preferences
            do { try saveOwners(updated) } catch { networkPrivacy = previous; throw error }
            return true
        } catch {
            errorMessage = "Не удалось сохранить настройки домашних сетей. Прежние правила сохранены."
            return false
        }
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
        try storage.save(SavedState(identity: identity, guests: updated, journal: journal, actionCode: actionCode, owners: owners, usedOwnerPresses: usedOwnerPresses, pendingRestore: pendingRestore, delegations: delegations, passedAccess: passedAccess, receivedDelegations: receivedDelegations, incomingMessages: incomingMessages, outgoingMessages: outgoingMessages, delegatedJournalLedger: delegatedJournalLedger, appLockEnabled: appLockEnabled, appEntryBiometricEnabled: appEntryBiometricEnabled, objectPreferences: preferences, bleAutomationDisarmed: bleAutomationDisarmed, ownerGuestDefaults: ownerGuestDefaults, companies: companies, androidArchives: androidArchives, androidPendingGuests: androidPendingGuests, selectedOwnerServer: selectedOwnerServer, networkPrivacy: networkPrivacy))
        guests = updated
        syncNetworkPrivacyRouting()
        if objectPreferences != preferences { objectPreferences = preferences }
    }

    @discardableResult func saveObjectPreferences(_ preferences: ObjectCatalogPreferences) -> Bool {
        guard canManageGuestAccess, !busy, !ownerBusy else { return false }
        do { try save(guests, preferences: preferences); return true }
        catch { errorMessage = "Не удалось сохранить настройки объекта. Прежние настройки сохранены."; return false }
    }

    func makeOwnerLive(_ owner: OwnerAccount) throws -> OwnerLiveTransport {
        guard storageReady, foreground, owner.ownershipLost != true,
              owners.contains(where:{ $0.server == owner.server && $0.credentials == owner.credentials && $0.ownershipLost != true }),
              let credentials = owner.credentials else { throw GuestCrypto.Failure.invalidEnvelope }
        return try ownerAPI.live(server: owner.server, credentials: credentials, fingerprint: GuestCrypto.hash(identity + Data(owner.server.utf8)))
    }

    func consumeOwnerPress(_ key: String) throws {
        guard usedOwnerPresses[key] == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        let previous = usedOwnerPresses
        usedOwnerPresses = usedOwnerPresses.filter { Date().timeIntervalSince($0.value) < 1500 }
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
        _ = try networkPrivacy.merging(payload.networkPrivacy)
        _ = try objectPreferences.merging(payload.objectPreferences)
        var mergedArchives = androidArchives
        for archive in payload.androidArchives ?? [] where !mergedArchives.contains(where:{ $0.archiveID == archive.archiveID }) { mergedArchives.append(archive) }
        try AndroidBackupDocument.validateArchives(mergedArchives)
        var mergedCompanies = companies
        for company in payload.companies ?? [] where !mergedCompanies.contains(where:{ $0.id == company.id }) { mergedCompanies.append(company) }
        try KnownCompany.validateDirectory(mergedCompanies)
        let existingIDs = Set(guests.map(\.id) + androidPendingGuests.map(\.id))
        guard existingIDs.union(payload.guests.map(\.id)).union((payload.androidGuests ?? []).map(\.id)).count <= 1000 else { throw BackupFailure.invalidPayload }
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
        for source in payload.androidGuests ?? [] {
            if let current = guests.first(where:{ $0.id == source.id }), current.invite.bundleKey != source.bundleKey { throw BackupFailure.conflictingAccess }
            if let current = androidPendingGuests.first(where:{ $0.id == source.id }) {
                guard current.bundleKey == source.bundleKey,
                      current.recipient?.privateKey == source.recipient?.privateKey,
                      current.recipient?.publicKey == source.recipient?.publicKey else { throw BackupFailure.conflictingAccess }
            }
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
        guard storageReady, foreground, !appLocked, !ownerBusy, !busy else { throw BackupFailure.busy }
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
            // activate follows a successful explicit host_claim in the durable
            // restore plan. Ordinary sync can never clear known ownership loss.
            if owner.credentials != nil { imported.ownershipLost = false }
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
        let previous = pendingRestore, priorLatches = bleAutomationDisarmed
        for object in owner.objects ?? [] where object.kind == "ble" { bleAutomationDisarmed.insert(ObjectReference.owned(server:owner.server,objectID:object.id).id) }
        pendingRestore = plan
        do { try saveOwners(updated) } catch { pendingRestore = previous; bleAutomationDisarmed = priorLatches; throw error }
    }
    func activateBackupGuest(_ guest: SavedGuest, plan: BackupRestorePlan) throws {
        var updated = guests
        if let index = updated.firstIndex(where:{ $0.id == guest.id }) {
            guard updated[index].invite == guest.invite else { throw BackupFailure.conflictingAccess }
            updated[index].requiresBLEExitOnRestore = true
            let current = try NetworkPrivacyPreferences(own:updated[index].privacyNetworks ?? [])
            updated[index].privacyNetworks = try current.merging(NetworkPrivacyPreferences(own:guest.privacyNetworks ?? [])).own
        } else {
            var imported = guest
            imported.requiresBLEExitOnRestore = true
            imported.objects = []; imported.checkedAt = nil
            updated.append(imported)
        }
        let previous = pendingRestore, priorLatches = bleAutomationDisarmed
        for object in guest.objects where object.kind == "ble" { bleAutomationDisarmed.insert(ObjectReference.received(guestID:guest.id,objectID:object.id).id) }
        pendingRestore = plan
        do { try save(updated) } catch { pendingRestore = previous; bleAutomationDisarmed = priorLatches; throw error }
    }
    func activatePendingAndroidGuest(_ source: AndroidGuestMigration,plan: BackupRestorePlan) throws {
        guard !guests.contains(where:{ $0.id == source.id }) else { throw BackupFailure.conflictingAccess }
        let previous = androidPendingGuests, previousPlan = pendingRestore
        if !androidPendingGuests.contains(where:{ $0.id == source.id }) { androidPendingGuests.append(source) }
        pendingRestore = plan
        do { try save(guests) } catch { androidPendingGuests = previous; pendingRestore = previousPlan; throw error }
    }
    func acceptRecoveredAndroidGuest(_ invite: GuestInvite) throws {
        guard canManageGuestAccess,
              let source = androidPendingGuests.first(where:{ $0.id == invite.id }) else { throw BackupFailure.noAccess }
        let previous = androidPendingGuests
        androidPendingGuests.removeAll { $0.id == invite.id }
        do { try save(guests + [SavedGuest(invite:invite,requiresBLEExitOnRestore:true,androidAutomation:source.incomingAutomation,privacyNetworks:source.privacyNetworks)]) }
        catch { androidPendingGuests = previous; throw error }
    }
    func removeImportedGuestRecovery(_ id: String) {
        guard canManageGuestAccess, !busy else { return }
        let previous = androidPendingGuests
        androidPendingGuests.removeAll { $0.id == id }
        do { try save(guests) }
        catch { androidPendingGuests = previous; errorMessage = "Не удалось сохранить удаление ключа." }
    }
    func finishBackupRestore(_ plan: BackupRestorePlan) throws {
        let previousNetworkPrivacy = networkPrivacy
        let previousPlan = pendingRestore, previousJournal = journal, previousPresses = usedOwnerPresses
        let previousPassed = passedAccess
        let previousReceived = receivedDelegations
        let previousIncoming = incomingMessages, previousOutgoing = outgoingMessages
        let previousLedger = delegatedJournalLedger, previousDefaults = ownerGuestDefaults, previousCompanies = companies, previousArchives = androidArchives, previousServer = selectedOwnerServer
        let restoredPreferences = try objectPreferences.merging(plan.payload.objectPreferences)
        let restoredIncoming = try mergedIncoming(plan.payload.incomingMessages ?? [])
        let existing = Set(journal.map(\.id))
        journal += plan.payload.journal.filter { $0.isAction && !existing.contains($0.id) }
        journal.sort { $0.date > $1.date }; journal = Array(journal.prefix(500))
        for (key, date) in plan.payload.usedOwnerPresses where Date().timeIntervalSince(date) < 1500 {
            usedOwnerPresses[key] = date
        }
        usedOwnerPresses = usedOwnerPresses.filter { Date().timeIntervalSince($0.value) < 1500 }
        guard usedOwnerPresses.count <= 2048 else {
            journal = previousJournal; usedOwnerPresses = previousPresses
            throw BackupFailure.busy
        }
        for source in plan.payload.passedAccess ?? [] {
            if !passedAccess.contains(where: { $0.id == source.id || (source.group != nil && $0.server == source.server && $0.group == source.group) }) { passedAccess.append(source) }
        }
        do {
            networkPrivacy = try networkPrivacy.merging(plan.payload.networkPrivacy)
            for owner in owners where owner.privacyNetworks != nil {
                networkPrivacy = try networkPrivacy.merging(NetworkPrivacyPreferences(own:owner.privacyNetworks!))
            }
            for source in plan.payload.receivedDelegations ?? [] {
                if let i = receivedDelegations.firstIndex(where: { $0.id == source.id }) { try receivedDelegations[i].merge(source) }
                else { receivedDelegations.append(source) }
            }
            incomingMessages = restoredIncoming
            for row in plan.payload.outgoingMessages ?? [] where !outgoingMessages.contains(where: { $0.id == row.id }) { outgoingMessages.append(row) }
            outgoingMessages.sort { $0.created > $1.created }; outgoingMessages = Array(outgoingMessages.prefix(100))
            if let ledger = plan.payload.delegatedJournalLedger { try delegatedJournalLedger.merge(ledger) }
            pendingRestore = nil
            if let host = plan.payload.selectedOwnerServer { selectedOwnerServer = host }
            for company in plan.payload.companies ?? [] where !companies.contains(where:{ $0.id == company.id }) { companies.append(company) }
            try KnownCompany.validateDirectory(companies)
            for archive in plan.payload.androidArchives ?? [] where !androidArchives.contains(where:{ $0.archiveID == archive.archiveID }) { androidArchives.append(archive) }
            try AndroidBackupDocument.validateArchives(androidArchives)
            var refreshedOwners = owners
            for index in refreshedOwners.indices where !networkPrivacy.own.isEmpty || refreshedOwners[index].privacyNetworks != nil {
                try refreshedOwners[index].setPrivacyNetworks(networkPrivacy.own)
            }
            if let defaults = plan.payload.ownerGuestDefaults {
                ownerGuestDefaults = defaults
                for index in refreshedOwners.indices where refreshedOwners[index].hostLabel != defaults.ownerName {
                    refreshedOwners[index].hostLabel = defaults.ownerName
                    for key in refreshedOwners[index].issuedKeys ?? [] { refreshedOwners[index].queueKeySettings(key.id) }
                }
            }
            try saveOwners(refreshedOwners, preferences:restoredPreferences)
        } catch {
            networkPrivacy = previousNetworkPrivacy
            pendingRestore = previousPlan; journal = previousJournal; usedOwnerPresses = previousPresses
            passedAccess = previousPassed; receivedDelegations = previousReceived
            incomingMessages = previousIncoming; outgoingMessages = previousOutgoing
            delegatedJournalLedger = previousLedger; ownerGuestDefaults = previousDefaults; companies = previousCompanies; androidArchives = previousArchives; selectedOwnerServer = previousServer; throw error
        }
    }

    private func saveOwners(_ updated: [OwnerAccount], preferences: ObjectCatalogPreferences? = nil) throws {
        let preferences = preferences ?? objectPreferences
        try preferences.validate()
        try storage.save(SavedState(identity: identity, guests: guests, journal: journal, actionCode: actionCode, owners: updated, usedOwnerPresses: usedOwnerPresses, pendingRestore: pendingRestore, delegations: delegations, passedAccess: passedAccess, receivedDelegations: receivedDelegations, incomingMessages: incomingMessages, outgoingMessages: outgoingMessages, delegatedJournalLedger: delegatedJournalLedger, appLockEnabled: appLockEnabled, appEntryBiometricEnabled: appEntryBiometricEnabled, objectPreferences: preferences, bleAutomationDisarmed: bleAutomationDisarmed, ownerGuestDefaults: ownerGuestDefaults, companies: companies, androidArchives: androidArchives, androidPendingGuests: androidPendingGuests, selectedOwnerServer: selectedOwnerServer, networkPrivacy: networkPrivacy))
        owners = updated
        syncNetworkPrivacyRouting()
        bleInformation = bleInformation.filter { target,info in
            guard case let .owned(server,id) = target,
                  let owner = updated.first(where:{ $0.server == server && $0.ownershipLost != true }) else { return false }
            return owner.objects?.contains(where:{ $0.id == id && $0.bleDeviceID == info.deviceID }) == true
        }
        if objectPreferences != preferences { objectPreferences = preferences }
        scheduleOwnerSettingsRefresh()
    }

    private func updateGuestMaterial(_ guest: inout SavedGuest, objects: [GuestObject], bundle: Data, snapshot: Data) throws {
        if guest.requiresBLEExitOnRestore == true, objects.contains(where:{ $0.kind == "ble" }) {
            for object in objects where object.kind == "ble" { bleAutomationDisarmed.insert(ObjectReference.received(guestID:guest.id,objectID:object.id).id) }
            guest.requiresBLEExitOnRestore = false
        }
        guard let contents = try JSONSerialization.jsonObject(with: bundle) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        guard contents["welcome"] == nil || contents["welcome"] is String,
              ((contents["welcome"] as? String)?.utf8.count ?? 0) <= 16384 else { throw GuestCrypto.Failure.invalidEnvelope }
        guest.welcome = contents["welcome"] as? String
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
            else if let imported = guest.androidAutomation?[String(object.numberID)] { rules[object.id] = try imported.receiving(fresh) }
            else { rules[object.id] = IncomingAutomationConfiguration(owner: fresh) }
            guest.androidAutomation?.removeValue(forKey:String(object.numberID))
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
              allowsAction(.received(guestID:intent.guestID,objectID:intent.object.id),automatic:intent.automatic), !busy, let guest = guests.first(where: { $0.id == intent.guestID }),
              !guest.paused, guest.objects.contains(intent.object), let cache = guest.bleCache,
              cache.revision == intent.revision else { throw BLETransportFailure.cancelled }
        let target = ObjectReference.received(guestID:intent.guestID,objectID:intent.object.id)
        if intent.automatic {
            guard let evidence = automaticPermits[target], automaticEvidenceValid(evidence,target:target),
                  !automation.bleOpenish(target) else { throw BLETransportFailure.cancelled }
        }
        let material = try cache.open(key: guest.invite.bundleKey)
        let decoded = try GuestActionPolicy.decodeBLE(bundle: material.bundle, numberID: intent.object.numberID,
            epoch: max(cache.maximumEpoch, UInt64(max(0, Date().timeIntervalSince1970))), overrides: guest.automation?[intent.object.id], readiness: conditionReadiness(.received(guestID: intent.guestID, objectID: intent.object.id)))
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
        journal.insert(JournalEntry(who: intent.automatic ? ProductText.string("journal_who_geo") : "Я", what: intent.object.label, actionKey: actionKey,
            result: "Результат Bluetooth-команды не получен", level: "warning"), at: 0)
        journal = Array(journal.prefix(500))
        let priorLatches = bleAutomationDisarmed
        bleAutomationDisarmed.insert(ObjectReference.received(guestID:intent.guestID,objectID:intent.object.id).id)
        do { try save(updated) } catch { journal = previous; bleAutomationDisarmed = priorLatches; throw error }
        bleAuthorizedIntent = nil
        noteAutomationAttempt(.received(guestID:intent.guestID,objectID:intent.object.id))
        return actionKey
    }
    func isBLEGuestAuthorized(_ id: UUID) -> Bool {
        guard bleAuthorizedIntent == id else { return false }
        return canManageGuestAccess || bleAuthorizedAutomaticTarget.map { allowsAction($0,automatic:true) } == true
    }
    func finishBLEGuestAuthorization(_ id: UUID) { if bleAuthorizedIntent == id { bleAuthorizedIntent = nil; bleAuthorizedAutomaticTarget = nil } }

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

    func ownerActionWho(server: String, objectID: UUID) -> String {
        activeOwnerAction?.server == server && activeOwnerAction?.object.id == objectID && activeOwnerAction?.automatic == true
            ? ProductText.string("journal_who_geo") : "Я"
    }

    func ownerManualActionAllowed(_ object: OwnerObject, server: String, action: GuestAction) -> Bool {
        guard ownerAccessIsUsable(server) else { rejectOwnerAction(object.id, ProductText.string("ios_server_ownership_lost")); return false }
        do {
            let target = ObjectReference.owned(server:server,objectID:object.id)
            if activeOwnerAction?.automatic == true {
                guard let evidence = automaticPermits[target], automaticEvidenceValid(evidence,target:target),
                      object.kind != "ble" || !automation.bleOpenish(target) else { return false }
            }
            let policy = try OwnerManualPolicy(object.localPolicy, readiness: conditionReadiness(target))
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
    func ownerPhysicalActionAllowed(server: String, objectID: UUID) -> Bool {
        if canManageGuestAccess { return true }
        guard let intent = activeOwnerAction, intent.automatic, intent.server == server, intent.object.id == objectID,
              let current = owners.first(where:{ $0.server == server })?.objects?.first(where:{ $0.id == objectID }) else { return false }
        // The sole expected mutation during an authorized BLE operation is its
        // durable consumed-nonce ledger. Secret, policy, identity and routing
        // must still match the frozen intent after that write completes.
        var expected = intent.object; expected.bleProofs = current.bleProofs
        guard current == expected else { return false }
        return allowsAction(.owned(server:server,objectID:objectID),automatic:true)
    }
    func beginBLEOwnerAction(server: String, objectID: UUID, proofHash: String) throws -> String {
        guard ownerPhysicalActionAllowed(server:server,objectID:objectID), let i = owners.firstIndex(where: { $0.server == server }),
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
        journal.insert(JournalEntry(who: ownerActionWho(server:server,objectID:objectID), what: label, actionKey: actionKey,
            result: "Результат Bluetooth-команды не получен", level: "warning"), at: 0)
        journal = Array(journal.prefix(500))
        let priorLatches = bleAutomationDisarmed
        bleAutomationDisarmed.insert(ObjectReference.owned(server:server,objectID:objectID).id)
        do { try saveOwners(updated) } catch { journal = previous; bleAutomationDisarmed = priorLatches; throw error }
        noteAutomationAttempt(.owned(server:server,objectID:objectID))
        return actionKey
    }

    func saveBLEPairing(_ record: BLEPairingRecord, server: String) throws {
        guard canManageGuestAccess, ownerAccessIsUsable(server), !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }),
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
            var reserved = try OwnerAccount(server:host); reserved.hostLabel = ownerGuestDefaults.ownerName; reserved.privacyNetworks = networkPrivacy.own
            var settings = OwnerServerSettings(); settings.accessCode = accessCode
            try settings.validate(); reserved.serverSettings = settings
            try saveOwners(owners + [reserved])
        } catch {
            errorMessage = "Не удалось сохранить сервер в защищённом хранилище. Регистрация не отправлялась."
            return false
        }
        return await registerReservedOwner(host,accessCode:accessCode,accountToken:nil,suiteChecked:false)
    }

    private func registerReservedOwner(_ host: String,accessCode: String,accountToken: String?,suiteChecked: Bool) async -> Bool {
        var markedThisAttempt = false
        do {
            if !suiteChecked, !(try await ownerAPI.supportsOwnerSuite(server:host)) { errorMessage = ProductText.string("server_suite_mismatch"); return false }
            guard canManageGuestAccess, let index = owners.firstIndex(where:{ $0.server == host }), owners[index].canRegisterSafely else { return false }
            var updated = owners
            try updated[index].markRegistrationSent()
            if updated[index].serverSettings?.pendingAccount != nil { updated[index].serverSettings?.pendingAccount?.sent = true }
            try saveOwners(updated)
            markedThisAttempt = true
            let credentials = try await ownerAPI.register(server:host,accessCode:accessCode,accountToken:accountToken)
            unsavedOwnerCredentials[host] = credentials
            try persistOwnerCredentials(host)
            await syncOwner(host)
            return true
        } catch {
            if (error as? GuestAPI.Failure)?.code == "network_policy_blocked",
               let index = owners.firstIndex(where:{ $0.server == host && $0.credentials == nil }) {
                var updated = owners
                do {
                    if markedThisAttempt {
                        try updated[index].resetUnsentRegistration()
                        try saveOwners(updated)
                    }
                    ownerMessages[host] = ProductText.string("ios_privacy_blocked"); errorMessage = ownerMessages[host]; return false
                } catch { /* Keep the sent reservation if persistence fails. */ }
            }
            if let failure = error as? OwnerAPI.Failure, failure.code == "access_denied", (400..<500).contains(failure.status),
               let index = owners.firstIndex(where:{ $0.server == host && $0.credentials == nil }) {
                var updated = owners
                do {
                    try updated[index].rejectRegistration(); try saveOwners(updated)
                    ownerMessages[host] = ProductText.string("server_access_denied"); errorMessage = ownerMessages[host]; return false
                } catch { /* retain the sent reservation if the rejection cannot be saved */ }
            }
            if unsavedOwnerCredentials[host] != nil {
                ownerMessages[host] = "Ответ получен, но сохранить доступ не удалось. Нажмите «Сохранить доступ», не закрывая приложение."
            } else if owners.first(where:{ $0.server == host })?.canRegisterSafely == true {
                ownerMessages[host] = ProductText.string("ios_server_save_failed")
            } else { ownerMessages[host] = ProductText.string("ios_server_registration_uncertain") }
            errorMessage = ownerMessages[host]
            return false
        }
    }

    private func persistOwnerCredentials(_ host: String) throws {
        guard let credentials = unsavedOwnerCredentials[host],
              let index = owners.firstIndex(where: { $0.server == host }) else { return }
        var updated = owners
        updated[index].credentials = credentials
        updated[index].registrationPhase = nil
        let previous = selectedOwnerServer; selectedOwnerServer = host
        do { try saveOwners(updated) } catch { selectedOwnerServer = previous; throw error }
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

    private func syncOwner(_ host: String, fulfillDelegations: Bool = true) async {
        guard let credentials = owners.first(where: { $0.server == host && $0.ownershipLost != true })?.credentials else { return }
        do {
            let fingerprint = GuestCrypto.hash(identity + Data(host.utf8))
            let data = try await ownerAPI.sync(server: host, credentials: credentials, fingerprint: fingerprint)
            let snapshot = try OwnerSnapshot.decode(data)
            guard pendingRestore == nil else { return }
            guard let index = owners.firstIndex(where: { $0.server == host && $0.ownershipLost != true && $0.credentials == credentials }) else { return }
            let previousOwner = owners[index]
            let previousObjects = previousOwner.objects ?? []
            var updated = owners
            try updated[index].reconcileObjects(snapshot)
            try updated[index].reconcileAccount(snapshot)
            updated[index].reservedGuestIDs = allReservedGuestIDs()
            try updated[index].reconcileAndroidKeys(snapshot)
            try updated[index].reconcileIssuedKeys(snapshot)
            let unverified = try updated[index].reconcileDelegatedKeys(snapshot)
            updated[index].queueObjectKeyRotations(after: previousOwner)
            try updated[index].prepareObjectKeyRotations()
            if updated[index].hasObjectKeyRotations {
                _ = try updated[index].reconcileDelegatedKeys(snapshot)
            }
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
            if fulfillDelegations { await fulfillVerifiedDelegations(server: host) }
        } catch {
            let code = (error as? OwnerAPI.Failure)?.code
            if ["evicted", "wrong_device", "bad_fp"].contains(code ?? "") { recordOwnerAccessLoss(host) }
            ownerMessages[host] = ["evicted", "wrong_device", "bad_fp"].contains(code ?? "")
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
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }), !owners[index].isMoving(objectID),
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
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }), !owners[index].isMoving(objectID),
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
                if key.state == .revoked || (key.pending == nil && (key.objectSettingsToken == token || key.effectiveNumberIDs?.isEmpty == true)) {
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
        await flushOwnerObjectKeyRotations(server: server)
    }

    /// Android Vault.rotateObjectKey: bundles first, encrypted metadata second.
    /// Metadata retries reuse the SAME durable key/cipher, never an opening.
    private func flushOwnerObjectKeyRotations(server: String) async {
        guard canManageGuestAccess,
              let owner = owners.first(where: { $0.server == server && $0.ownershipLost != true }) else { return }
        for id in (owner.objects ?? []).filter({ $0.keyRotation != nil }).map(\.id) {
            let retryID = server + "|rotation:" + id.uuidString
            if let next = ownerBundleRetryAfter[retryID], next > Date() { continue }
            do {
                guard canManageGuestAccess,
                      let i = owners.firstIndex(where: { $0.server == server && $0.ownershipLost != true }),
                      let credentials = owners[i].credentials,
                      let j = owners[i].objects?.firstIndex(where: { $0.id == id }),
                      let snapshot = ownerSnapshots[server],
                      try owners[i].canPublishKeyRotation(objectID: id, snapshot: snapshot),
                      let rotation = owners[i].objects![j].keyRotation,
                      let number = owners[i].objects![j].numberID,
                      let revision = owners[i].objects![j].revision else { continue }
                var updated = owners
                updated[i].objects![j].keyRotation?.sent = true
                try saveOwners(updated) // No network before this checkpoint.
                guard canManageGuestAccess, owners[i].credentials == credentials else { return }
                deferOwnerSettingsRetry(retryID)
                let body = try JSONSerialization.data(withJSONObject: ["id": number,
                    "data_cipher": rotation.cipher, "data_cipher_ts_check": revision], options: .sortedKeys)
                let data = try await ownerAPI.mutate(server: server, credentials: credentials,
                    fingerprint: backupFingerprint(server: server), operation: .update, body: body)
                guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (reply["ok"] as? NSNumber)?.boolValue == true else { throw GuestCrypto.Failure.invalidEnvelope }
                await syncOwner(server)
                if owners.first(where: { $0.server == server })?.objects?.first(where: { $0.id == id })?.keyRotation == nil {
                    ownerBundleRetryAfter.removeValue(forKey: retryID); ownerBundleRetryAttempts.removeValue(forKey: retryID)
                    ownerObjectMessages.removeValue(forKey: id)
                }
            } catch {
                deferOwnerSettingsRetry(retryID)
                ownerObjectMessages[id] = "Смена ключа объекта ожидает синхронизации. Сохранённые ключи и запись не потеряны."
            }
        }
    }

    private func deferOwnerSettingsRetry(_ id: String) {
        let attempt = min(6, ownerBundleRetryAttempts[id] ?? 0)
        ownerBundleRetryAfter[id] = Date().addingTimeInterval(min(1800, 30 * pow(2, Double(attempt))))
        ownerBundleRetryAttempts[id] = attempt + 1
    }

    private func scheduleOwnerSettingsRefresh() {
        guard ownerSettingsTask == nil, foreground, owners.contains(where: { !($0.bundleRefreshQueue ?? [:]).isEmpty || $0.hasObjectKeyRotations }) else { return }
        let generation = UUID()
        ownerSettingsTaskGeneration = generation
        ownerSettingsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                guard let self, self.foreground else { break }
                guard self.owners.contains(where: { !($0.bundleRefreshQueue ?? [:]).isEmpty || $0.hasObjectKeyRotations }) else { break }
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
        guard storageReady, !ownerBusy, let index = owners.firstIndex(where: { $0.server == server }), !owners[index].isMoving(objectID),
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
            updated[index].objects![offset].keyRotation = nil
            updated[index].objects![offset].keyRotationQueued = nil
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

    /// Android HostService.syncHostData/Vault.fulfilDelegatedKey: a verified
    /// recipient does not need another owner approval. Each exact blob is saved
    /// before upload; an uncertain sent blob is reconciled, not regenerated.
    private func fulfillVerifiedDelegations(server: String) async {
        var attempted = Set<UUID>()
        // A confirmed parent can unlock its next descendant. Five passes match
        // the protocol depth and keep this work bounded for hostile snapshots.
        for _ in 0..<5 {
            guard canManageGuestAccess, ownerMessages[server] == nil,
                  let owner = owners.first(where: { $0.server == server }) else { return }
            let pending = (owner.delegatedKeys ?? []).filter {
                $0.state == .awaiting && !$0.sent && $0.revocationPending != true && !attempted.contains($0.id)
            }.map(\.id)
            guard !pending.isEmpty else { return }
            for id in pending {
                guard canManageGuestAccess else { return }
                attempted.insert(id)
                await sendVerifiedDelegation(server: server, keyID: id, retry: false)
            }
        }
    }

    func approveDelegatedKey(server: String, keyID: UUID, retry: Bool = false) async {
        guard canManageGuestAccess, !ownerBusy, !busy else { return }
        ownerBusy = true
        defer { ownerBusy = false }
        await syncOwner(server, fulfillDelegations: false)
        guard ownerMessages[server] == nil else { return }
        await sendVerifiedDelegation(server: server, keyID: keyID, retry: retry)
        await fulfillVerifiedDelegations(server: server)
    }

    private func sendVerifiedDelegation(server: String, keyID: UUID, retry: Bool) async {
        guard canManageGuestAccess,
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
            let data = try await ownerAPI.mutate(server: server, credentials: credentials,
                fingerprint: backupFingerprint(server: server), operation: .keyEdit, body: body)
            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (reply["ok"] as? NSNumber)?.boolValue == true else { throw GuestCrypto.Failure.invalidEnvelope }
            await syncOwner(server, fulfillDelegations: false)
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
            await flushOwnerObjectSettings(server: server)
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
            let defaults = ownerGuestDefaults.access
            let initialAccess = try access ?? Dictionary(uniqueKeysWithValues:numberIDs.map { ($0,try KeyObjectAccess(nativeOnly:nativeOnly || defaults.nativeOnly,depth:defaults.depth,pool:defaults.pool)) })
            let key = try OwnerIssuedKey(owner: authority, label: label, numberIDs: numberIDs, welcome: welcome, nativeOnly: nativeOnly, confirmation: confirmation, access: initialAccess, settings: settings)
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
            let saved = await sendOwnerKey(server: server, keyID: keyID)
            await flushOwnerObjectSettings(server: server)
            return saved
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
            await flushOwnerObjectSettings(server: server)
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
            if operation == .keyCreate {
                let replyID = try OwnerObject.replyID(json["id"])
                guard !(updated[i].issuedKeys ?? []).contains(where:{ $0.id != keyID && $0.keyID == replyID }) else { throw GuestCrypto.Failure.invalidEnvelope }
                try updated[i].issuedKeys![j].acceptCreationReply(json)
            }
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
        guard canManageGuestAccess, !busy else { return false }
        do {
            let invite = try GuestInvite.parse(text)
            if let source = androidPendingGuests.first(where:{ $0.id == invite.id }) {
                guard let recovered = try await api.recover(identity:source.identity,bundleKey:invite.bundleKey,recipient:source.recipient,fingerprint:backupFingerprint(server:invite.server)) else { throw BackupFailure.pendingAccess }
                try acceptRecoveredAndroidGuest(recovered)
                await refresh(); return true
            }
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
        guard storageReady, foreground, !busy else { return }
        if !androidPendingGuests.isEmpty { await backups.refreshImportedGuests() }
        guard !guests.isEmpty else { return }
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
                try rememberGuestNetworkRestrictions(bundle:bundle,id:entry.id)
                if !ServerSessionPolicy.shared.networkPrivacyEnforced,
                   let b = try JSONSerialization.jsonObject(with: bundle) as? [String: Any],
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
        if backgroundMonitoring { stopBackgroundCommand() }
        backgroundMonitoring = false; backgroundActionScope = nil
        foreground = true
        scheduleOwnerSettingsRefresh()
        automation.resume()
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

    func suspend(preserveAutomation: Bool = false) {
        backgroundMonitoring = false; backgroundActionScope = nil
        incomingMessagePromptID = nil; localTaskDialogs.removeAll()
        diagnosticConsentPrompt = false; diagnostics.pause(); promotions.pause(); remoteNotifications.pause()
        networkPrivacyPrompt = nil
        bleInformationTarget = nil
        if let prompt = actionPrompt { dismissActionPrompt(prompt.id) }
        confirmedAutomaticPromptID = nil; executingActionPrompt = nil
        codePrompt = nil
        serverPrompt = nil
        backupPresentation.cancel()
        if preserveAutomation { automation.pauseForBackground() } else { automation.suspend() }
        automaticPermits.removeAll()
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
        bleAuthorizedAutomaticTarget = nil
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
              let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guests.first(where: { $0.id == guestID })?.automation?[object.id], readiness: conditionReadiness(.received(guestID: guestID, objectID: object.id))) else {
            return "Управлять"
        }
        let action = chosenGuestAction(policy: policy, numberID: object.numberID, positions: link.positions)
        return ActionIntent.displayTitle(action: action, kind: policy.kind)
    }

    func objectConnectionTitle(guestID: String, object: GuestObject) -> String {
        guard let link = actionLinks[guestID], connection(for: guestID) == .connected,
              let bundle = link.bundle, let snapshot = link.snapshot,
              let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guests.first(where: { $0.id == guestID })?.automation?[object.id], readiness: conditionReadiness(.received(guestID: guestID, objectID: object.id))) else {
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
            if let removed { remoteNotifications.removed(removed.invite) }
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
        do {
            try save(guests)
            if previous[index].result != result || previous[index].level != level {
                if level == "success" { AppSoundCenter.shared.play(.success) }
                else if level == "error" || level == "danger" { AppSoundCenter.shared.play(.error) }
            }
        }
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
                    try self.rememberGuestNetworkRestrictions(bundle:currentBundle,id:entry.id)
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
        try rememberGuestNetworkRestrictions(bundle:bundle,id:entry.id)
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
        if let event = DiagnosticEvent.Code(rawValue:code) { diagnostics.record(event) }
        let allowed = GuestEvent.terminalReasons.union(["connection_failed", "storage_error", "paused", "network_policy_unsupported", "network_policy_blocked", "awaiting_owner", "server_error", "replay", "invalid_response", "rate_limited", "too_many_requests", "device_binding_failed", "event_overflow"])
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
        case "network_policy_blocked": return ProductText.string("ios_privacy_blocked")
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
    var automatic = false
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
    var attempt: (journalID: UUID, numberID: Int, key: String, template: Data, automatic: AutomationReadiness?)?
    var timeout: Task<Void, Never>?
    init(live: GuestActionTransport) { self.live = live }
}

extension AppModel {
    func actionIntent(guestID: String, object: GuestObject, automatic: Bool = false) -> ActionIntent? {
        if automatic && !automaticPermitValid(.received(guestID:guestID,objectID:object.id)) { return nil }
        guard objectIsVisible(.received(guestID: guestID, objectID: object.id)) else { return nil }
        actionRejections.removeValue(forKey: guestID + "|" + object.id)
        do {
            if object.kind == "ble" {
                guard allowsAction(.received(guestID:guestID,objectID:object.id),automatic:automatic), !busy, !bleGuestControl.busy,
                      let guest = guests.first(where: { $0.id == guestID }), !guest.paused,
                      guest.objects.contains(object), let cache = guest.bleCache else { throw ActionDenied.message("Защищённый Bluetooth-пропуск не сохранён. Обновите ключ через интернет.") }
                let material = try cache.open(key: guest.invite.bundleKey)
                let decoded = try GuestActionPolicy.decodeBLE(bundle: material.bundle, numberID: object.numberID,
                    epoch: max(cache.maximumEpoch, UInt64(max(0, Date().timeIntervalSince1970))), overrides: guest.automation?[object.id], readiness: conditionReadiness(.received(guestID: guest.id, objectID: object.id)))
                if let reason = decoded.policy.blockedReason { throw ActionDenied.message(reason) }
                let intent = ActionIntent(guestID: guestID, object: object, revision: cache.revision,
                    action: .toggle, wireAction: "toggle", policy: decoded.policy, automatic: automatic)
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
            let policy = try GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guests.first(where: { $0.id == guestID })?.automation?[object.id], readiness: conditionReadiness(.received(guestID: guestID, objectID: object.id)))
            if let reason = policy.blockedReason { throw ActionDenied.message(reason) }
            let reachable = policy.serverWebhook || (policy.kind == "device" ? policy.deviceID.map { link.devices.contains($0) } == true : link.hostOnline)
            guard reachable else { throw ActionDenied.message(policy.kind == "device" ? "Контроллер не в сети." : "Телефон владельца не в сети.") }
            let action: GuestAction = automatic ? .open : chosenGuestAction(policy: policy, numberID: object.numberID, positions: link.positions)
            let wire = action == .close ? "close" : (action == .toggle ? "toggle" : "")
            return ActionIntent(guestID: guestID, object: object, revision: link.revision, action: action, wireAction: wire, policy: policy, automatic: automatic)
        } catch let ActionDenied.message(text) { rejectAction(guestID: guestID, object: object, message: text) }
        catch BLECommandSession.Failure.expired { rejectAction(guestID: guestID, object: object, message: "Срок Bluetooth-пропуска истёк. Обновите ключ через интернет; продление разрешает владелец.") }
        catch { rejectAction(guestID: guestID, object: object, message: "Не удалось проверить защищённые условия доступа к объекту.") }
        return nil
    }

    func execute(_ intent: ActionIntent) async {
        if intent.automatic && (intent.policy.confirmation || intent.policy.authentication != nil),
           !consumeAutomaticPromptConfirmation(intent.id) { return }
        // Recheck after confirmation/authentication. Never change the direction silently.
        if intent.policy.kind == "ble" {
            defer { finishBLEGuestAuthorization(intent.id) }
            guard let fresh = actionIntent(guestID: intent.guestID, object: intent.object, automatic: intent.automatic) else { return }
            guard fresh.revision == intent.revision, fresh.policy.template == intent.policy.template else {
                rejectAction(guestID: intent.guestID, object: intent.object, message: "Bluetooth-пропуск изменился. Нажмите на объект ещё раз."); return
            }
            let authenticated = authorizedIntent == intent.id; authorizedIntent = nil
            guard fresh.policy.authentication == nil || authenticated else { rejectAction(guestID: intent.guestID, object: intent.object, message: "Требуется подтверждение личности."); return }
            bleAuthorizedIntent = intent.id
            bleAuthorizedAutomaticTarget = intent.automatic ? .received(guestID:intent.guestID,objectID:intent.object.id) : nil
            await bleGuestControl.execute(intent)
            return
        }
        guard let fresh = actionIntent(guestID: intent.guestID, object: intent.object, automatic: intent.automatic) else { return }
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
            let entry = JournalEntry(who: intent.automatic ? ProductText.string("journal_who_geo") : "Я", what: intent.object.label, actionKey: key,
                                     result: "Результат не получен", level: "warning")
            let previous = journal
            journal.insert(entry, at: 0); journal = Array(journal.prefix(500))
            do { try save(guests) } catch { journal = previous; throw error }
            noteAutomationAttempt(.received(guestID:intent.guestID,objectID:intent.object.id))
            link.attempt = (entry.id, intent.object.numberID, key, intent.policy.template, intent.automatic ? automaticPermits[.received(guestID:intent.guestID,objectID:intent.object.id)] : nil)
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
                  let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guest.automation?[object.id], readiness: conditionReadiness(.received(guestID: guest.id, objectID: object.id))),
                  policy.blockedReason == nil, policy.template == attempt.template,
                  policy.deviceID.map({ link.devices.contains($0) }) == true else { return }
            if let evidence = attempt.automatic,
               !automaticEvidenceValid(evidence,target:.received(guestID:guestID,objectID:object.id)) { return }
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
                case "expired": text = ProductText.string("ios_guest_call_expired"); level = "warning"
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
        AppSoundCenter.shared.play(.biometric)
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
    func ownerActionIntent(server: String, objectID: UUID, automatic: Bool = false) -> OwnerActionIntent? {
        if automatic && !automaticPermitValid(.owned(server:server,objectID:objectID)) { return nil }
        ownerActionRejections.removeValue(forKey: objectID)
        do {
            guard allowsAction(.owned(server:server,objectID:objectID),automatic:automatic), !busy, !ownerBusy,
                  let owner = owners.first(where: { $0.server == server && $0.ownershipLost != true }),
                  let object = owner.objects?.first(where: { $0.id == objectID }),
                  !owner.registrationPending || object.kind == "ble", object.ownerCardAvailable, !owner.isMoving(objectID) else {
                throw ActionDenied.message("Объект сейчас недоступен.")
            }
            let policy = try OwnerManualPolicy(object.localPolicy, readiness: conditionReadiness(.owned(server: server, objectID: object.id)))
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
            let action: GuestAction = object.kind == "ble" ? .toggle : automatic ? .open :
                (object.kind == "device" && ["open", "opening"].contains(position ?? "") ? .close :
                (object.kind == "webhook" && metadata["wh_toggle"] as? Int == 1 ? .toggle : .open))
            return OwnerActionIntent(server: server, object: object, label: metadata["label"] as? String ?? "Объект", action: action, policy: policy, automatic: automatic)
        } catch let ActionDenied.message(message) { rejectOwnerAction(objectID, message) }
        catch { rejectOwnerAction(objectID, "Не удалось проверить защищённые данные объекта.") }
        return nil
    }
    private func ownerIntentStillValid(_ intent: OwnerActionIntent) -> Bool {
        guard ProcessInfo.processInfo.systemUptime - intent.created < 120,
              let fresh = ownerActionIntent(server: intent.server, objectID: intent.object.id, automatic: intent.automatic),
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
        if intent.automatic && (intent.policy.confirmation || intent.policy.authentication != nil),
           !consumeAutomaticPromptConfirmation(intent.id) { return }
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
            _ = try OwnerManualPolicy(object.localPolicy, readiness: conditionReadiness(.owned(server: server, objectID: object.id)))
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
    func verifySettingsCode(_ code: String) async throws -> Bool {
        guard canManageGuestAccess else { return false }
        return try await authorizeCode(code,authentication:"pin",requestID:nil)
    }
}


extension AppModel {
    /// Observational presentation state only. It never authorizes a command.
    func objectPosition(_ entry: CatalogObject) -> String? {
        guard ["ble","device","webhook"].contains(entry.kind) else { return nil }
        if entry.kind == "ble" {
            // Android hides OPEN corners when a BLE controller is no longer
            // reachable; an old observation must not remain visibly open.
            guard objectAvailability(entry) == .ready else { return nil }
            return automation.blePosition(entry.target)
        }
        switch entry {
        case let .owned(owner,object):
            return object.numberID.flatMap { ownerControl.positions[owner.server]?[$0] }
        case let .received(guest,object): return actionLinks[guest.id]?.positions[object.numberID]
        }
    }
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
                        epoch: max(cache.maximumEpoch, UInt64(max(0, Date().timeIntervalSince1970))), overrides: guest.automation?[object.id], readiness: conditionReadiness(.received(guestID: guest.id, objectID: object.id)))) != nil else { return .offline }
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
                  let policy = try? GuestActionPolicy.decode(bundle: bundle, snapshot: snapshot, numberID: object.numberID, overrides: guest.automation?[object.id], readiness: conditionReadiness(.received(guestID: guest.id, objectID: object.id))) else { return .unknown }
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
                guard let index = owners.firstIndex(where: { $0.server == server }), !owners[index].isMoving(id),
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

extension AppModel {
    func bleMove(server: String, objectID: UUID) -> OwnerBLEMove? {
        owners.first(where: { $0.server == server })?.bleMoves?.first(where: { $0.objectID == objectID })
    }
    func objectIsMoving(server: String, objectID: UUID) -> Bool { bleMove(server: server, objectID: objectID) != nil }

    func moveBLEObject(server: String, objectID: UUID, to destination: String) async -> Bool {
        guard canManageGuestAccess, !busy, !ownerBusy, server != destination,
              owners.contains(where: { $0.server == destination && $0.credentials != nil }),
              unsavedOwnerObjects[objectID] == nil else { return false }
        ownerBusy = true; defer { ownerBusy = false }
        do {
            if let existing = bleMove(server: server, objectID: objectID) {
                guard existing.destination == destination else { throw GuestCrypto.Failure.invalidEnvelope }
            } else {
                await syncOwner(server)
                guard ownerMessages[server] == nil, let index = owners.firstIndex(where: { $0.server == server }),
                      let object = owners[index].objects?.first(where: { $0.id == objectID }), let number = object.numberID,
                      !owners.contains(where: { account in
                          account.server == destination && (account.objects ?? []).contains(where: { $0.bleDeviceID == object.bleDeviceID })
                      }), !(owners[index].issuedKeys ?? []).contains(where: { $0.numberIDs.contains(number) && ($0.pending != nil || unsavedOwnerKeys[$0.id] != nil) }) else {
                    ownerObjectMessages[objectID] = "Сначала дождитесь подтверждения настроек объекта и его гостевых ключей."
                    return false
                }
                let move = try OwnerBLEMove(object: object, destination: destination)
                var updated = owners
                updated[index].bleMoves = (updated[index].bleMoves ?? []) + [move]
                var preferences = objectPreferences
                let actual = catalogObjects(includeHidden: true).map(\.target)
                preferences.order = actual + preferences.order.filter { !actual.contains($0) }
                try saveOwners(updated, preferences: preferences)
            }
            return try await continueBLEMove(server: server, objectID: objectID)
        } catch {
            ownerObjectMessages[objectID] = "Перенос не подтверждён. Секрет контроллера сохранён; проверьте результат. Новая привязка не выполнялась."
            return false
        }
    }
    private func moveSnapshot(_ server: String) async throws -> OwnerSnapshot {
        guard let owner = owners.first(where: { $0.server == server }), let credentials = owner.credentials else { throw GuestCrypto.Failure.invalidEnvelope }
        return try OwnerSnapshot.decode(await ownerAPI.sync(server: server, credentials: credentials,
            fingerprint: GuestCrypto.hash(identity + Data(server.utf8))))
    }
    private func moveRequest(_ server: String, operation: OwnerOperation, body: Data) async throws -> [String: Any] {
        guard let credentials = owners.first(where: { $0.server == server })?.credentials else { throw GuestCrypto.Failure.invalidEnvelope }
        let data = try await ownerAPI.mutate(server: server, credentials: credentials,
            fingerprint: GuestCrypto.hash(identity + Data(server.utf8)), operation: operation, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        return json
    }
    private func saveMove(_ move: OwnerBLEMove, server: String) throws {
        guard let i = owners.firstIndex(where: { $0.server == server }),
              let j = owners[i].bleMoves?.firstIndex(where: { $0.id == move.id }) else { throw GuestCrypto.Failure.invalidEnvelope }
        var updated = owners; updated[i].bleMoves![j] = move; try saveOwners(updated)
    }
    private func continueBLEMove(server: String, objectID: UUID) async throws -> Bool {
        var removedSourceThisAttempt = false, removedTargetThisAttempt = false
        for _ in 0..<8 {
            guard canManageGuestAccess, var move = bleMove(server: server, objectID: objectID) else { return false }
            switch move.phase {
            case .createPrepared:
                let request = try move.request(); try move.markSent(); try saveMove(move, server: server)
                do {
                    let response = try await moveRequest(move.destination, operation: .create, body: request)
                    try move.acceptedCreation(numberID: OwnerObject.replyID(response["id"]))
                    try saveMove(move, server: server)
                } catch let failure as OwnerAPI.Failure {
                    if [400,401,403,404,409,422].contains(failure.status) {
                        try move.rejectedCreation(); try saveMove(move, server: server)
                    }
                    throw failure
                }
            case .createSent:
                let target = try await moveSnapshot(move.destination)
                let found = try move.reconcileDestination(target)
                try saveMove(move, server: server)
                if !found { ownerObjectMessages[objectID] = "Ответ создания на новом сервере ещё не подтверждён. Проверка не создаёт вторую запись."; return false }
            case .removePrepared, .removeSent:
                let target = try await moveSnapshot(move.destination)
                guard try move.reconcileDestination(target) else { throw GuestCrypto.Failure.invalidEnvelope }
                let source = try await moveSnapshot(server)
                move.reconcileSource(source)
                if move.phase == .ready { try saveMove(move, server: server); continue }
                guard source.rows.contains(where: { $0["id"] as? Int == move.sourceNumberID && $0["type"] as? String == "ble" && $0["data_cipher"] as? String == move.cipher }) else {
                    if move.phase == .removePrepared { try move.rollback(); try saveMove(move, server: server); continue }
                    throw GuestCrypto.Failure.invalidEnvelope
                }
                if move.phase == .removeSent {
                    guard !removedSourceThisAttempt else { return false }
                    try move.retryIdempotentRemoval()
                }
                let request = try move.request(); try move.markSent(); try saveMove(move, server: server)
                removedSourceThisAttempt = true
                do {
                    let response = try await moveRequest(server, operation: .delete, body: request)
                    guard (response["ok"] as? NSNumber)?.boolValue == true else { throw GuestCrypto.Failure.invalidEnvelope }
                } catch let failure as OwnerAPI.Failure {
                    if [400,401,403,409,422].contains(failure.status) { try move.rollback(); try saveMove(move, server: server) }
                    else { throw failure }
                }
            case .rollbackPrepared, .rollbackSent:
                let target = try await moveSnapshot(move.destination)
                guard let destinationID = move.destinationNumberID else { throw GuestCrypto.Failure.invalidEnvelope }
                if !target.rows.contains(where: { $0["id"] as? Int == destinationID }) {
                    guard let index = owners.firstIndex(where: { $0.server == server }) else { return false }
                    var updated = owners; updated[index].bleMoves?.removeAll { $0.id == move.id }; try saveOwners(updated)
                    ownerObjectMessages[objectID] = "Перенос не выполнен. Запись на новом сервере отменена; исходный объект сохранён."
                    await syncOwner(server); return false
                }
                guard try move.reconcileDestination(target) else { throw GuestCrypto.Failure.invalidEnvelope }
                if move.phase == .rollbackSent {
                    guard !removedTargetThisAttempt else { return false }
                    try move.retryIdempotentRemoval()
                }
                let request = try move.request(); try move.markSent(); try saveMove(move, server: server)
                removedTargetThisAttempt = true
                let response = try await moveRequest(move.destination, operation: .delete, body: request)
                guard (response["ok"] as? NSNumber)?.boolValue == true else { throw GuestCrypto.Failure.invalidEnvelope }
            case .ready:
                let sourceSnapshot = try await moveSnapshot(server), targetSnapshot = try await moveSnapshot(move.destination)
                guard let fromIndex = owners.firstIndex(where: { $0.server == server }),
                      let toIndex = owners.firstIndex(where: { $0.server == move.destination }) else { throw GuestCrypto.Failure.invalidEnvelope }
                let (from, to, preferences) = try move.committed(source: owners[fromIndex], destination: owners[toIndex],
                    sourceSnapshot: sourceSnapshot, destinationSnapshot: targetSnapshot, preferences: objectPreferences)
                var updated = owners; updated[fromIndex] = from; updated[toIndex] = to
                let priorLatches = bleAutomationDisarmed
                let oldTarget = ObjectReference.owned(server:server,objectID:objectID).id
                if bleAutomationDisarmed.remove(oldTarget) != nil { bleAutomationDisarmed.insert(ObjectReference.owned(server:move.destination,objectID:objectID).id) }
                do { try saveOwners(updated, preferences: preferences) }
                catch { bleAutomationDisarmed = priorLatches; throw error }
                ownerObjectMessages.removeValue(forKey: objectID)
                await flushOwnerObjectSettings(server: server)
                await syncOwner(server); await syncOwner(move.destination)
                return true
            }
        }
        return false
    }
}

extension AppModel {
    func setBLEAutomationArmed(_ target: ObjectReference, armed: Bool) throws {
        guard canObserveAutomation, catalogObject(target)?.kind == "ble" else { throw BLETransportFailure.cancelled }
        let prior = bleAutomationDisarmed
        if armed { bleAutomationDisarmed.remove(target.id) } else { bleAutomationDisarmed.insert(target.id) }
        guard bleAutomationDisarmed != prior else { return }
        do { try save(guests) } catch { bleAutomationDisarmed = prior; throw error }
    }
}

extension AppModel {
    func ownerAccessIsUsable(_ host: String) -> Bool {
        // A locally authenticated BLE pairing may work before server metadata
        // registration finishes. Missing HTTP credentials are not an eviction.
        owners.contains { $0.server == host && $0.ownershipLost != true }
    }

    /// Once this device learns that its claim was lost, offline owner secrets
    /// cannot keep authorizing commands. Keep the denial even if storage fails.
    func recordOwnerAccessLoss(_ host: String) {
        guard let index = owners.firstIndex(where:{ $0.server == host }), owners[index].ownershipLost != true else { return }
        var updated = owners; updated[index].ownershipLost = true
        owners = updated
        ownerMessages[host] = ProductText.string("ios_server_ownership_lost")
        ownerSnapshots.removeValue(forKey:host)
        ownerControl.removeServer(host,unavailable:true)
        automaticPermits = automaticPermits.filter { if case .owned(let server,_) = $0.key { return server != host }; return true }
        do { try saveOwners(updated) }
        catch { errorMessage = ProductText.string("ios_server_loss_save_failed") }
    }

    @discardableResult func forgetOwnerServer(_ host: String) -> Bool {
        guard canManageGuestAccess, !ownerBusy, !busy, host != "entrixy.com",
              host == selectedOwnerServer || owners.contains(where:{ $0.server == host }) else { return false }
        let owner = owners.first(where:{ $0.server == host })
        guard !bleControl.busy, !blePairing.busy, !bleGuestControl.busy,
              !owners.contains(where:{ account in !(account.bleMoves ?? []).filter { account.server == host || $0.destination == host }.isEmpty }) else {
            errorMessage = ProductText.string("ios_server_forget_busy"); return false
        }
        let priorServer = selectedOwnerServer, priorOutgoing = outgoingMessages, priorLatches = bleAutomationDisarmed
        let targets = Set(((owner?.objects ?? []) + (owner?.bleArchivedObjects ?? [])).map { ObjectReference.owned(server:host,objectID:$0.id) })
        var preferences = objectPreferences
        preferences.order.removeAll { if case .owned(let server,_) = $0 { return server == host }; return false }
        if selectedOwnerServer == host { selectedOwnerServer = "entrixy.com" }
        outgoingMessages.removeAll { if case .owner(let server,_) = $0.target { return server == host }; return false }
        bleAutomationDisarmed = bleAutomationDisarmed.filter { !$0.hasPrefix("owner:" + host + ":") }
        do { try saveOwners(owners.filter { $0.server != host },preferences:preferences) }
        catch {
            selectedOwnerServer = priorServer; outgoingMessages = priorOutgoing; bleAutomationDisarmed = priorLatches
            errorMessage = ProductText.string("ios_server_save_failed"); return false
        }
        // No registration, delete, revoke or other server request is sent.
        ownerControl.removeServer(host)
        ownerSnapshots.removeValue(forKey:host); ownerMessages.removeValue(forKey:host)
        unverifiedOwnerDelegations.removeValue(forKey:host); unsavedOwnerCredentials.removeValue(forKey:host)
        for object in (owner?.objects ?? []) + (owner?.bleArchivedObjects ?? []) {
            ownerObjectMessages.removeValue(forKey:object.id); unsavedOwnerObjects.removeValue(forKey:object.id); ownerActionRejections.removeValue(forKey:object.id)
        }
        for key in owner?.issuedKeys ?? [] {
            unsavedOwnerKeys.removeValue(forKey:key.id); ownerKeyMessages.removeValue(forKey:key.id); editingOwnerKeys.remove(key.id)
        }
        for key in owner?.delegatedKeys ?? [] { ownerDelegationMessages.removeValue(forKey:key.id) }
        if activeOwnerAction?.server == host { activeOwnerAction = nil; authorizedIntent = nil }
        automaticPermits = automaticPermits.filter { !targets.contains($0.key) }
        automaticConsumedAt = automaticConsumedAt.filter { !targets.contains($0.key) }
        bleVisibleUntil = bleVisibleUntil.filter { !targets.contains($0.key) }
        return true
    }

    @discardableResult func selectOwnerServer(_ value: String) -> Bool {
        guard canManageGuestAccess, !ownerBusy, !busy,
              let host = try? GuestInvite.normalizeServer(value),
              host == "entrixy.com" || owners.contains(where:{ $0.server == host && $0.credentials != nil && $0.ownershipLost != true }) else { return false }
        let previous = selectedOwnerServer; selectedOwnerServer = host
        do { try save(guests); return true }
        catch { selectedOwnerServer = previous; errorMessage = ProductText.string("ios_server_save_failed"); return false }
    }

    func saveServerConfiguration(server: String,accessCode: String,email: String,password: String) async -> Bool {
        guard canManageGuestAccess, !ownerBusy, !busy else { return false }
        let host: String
        do { host = try GuestInvite.normalizeServer(server) }
        catch { errorMessage = ProductText.string("server_add_failed"); return false }
        let mail = email.trimmingCharacters(in:.whitespacesAndNewlines)
        guard mail.isEmpty == password.isEmpty else { errorMessage = ProductText.string("server_account_failed"); return false }
        if owners.contains(where:{ $0.server == host && $0.ownershipLost == true }) { errorMessage = ProductText.string("ios_server_ownership_lost"); return false }
        if let owner = owners.first(where:{ $0.server == host && $0.registrationPending }), !owner.canRegisterSafely {
            errorMessage = ownerMessages[host] ?? ProductText.string("ios_server_registration_uncertain"); return false
        }
        ownerBusy = true; defer { ownerBusy = false }
        do {
            guard try await ownerAPI.supportsOwnerSuite(server:host) else { errorMessage = ProductText.string("server_suite_mismatch"); return false }
            let token = mail.isEmpty ? nil : try await ownerAPI.accountLogin(server:host,email:mail,password:password)
            guard canManageGuestAccess else { return false }
            var updated = owners
            if !updated.contains(where:{ $0.server == host }) {
                var reserved = try OwnerAccount(server:host); reserved.hostLabel = ownerGuestDefaults.ownerName; reserved.privacyNetworks = networkPrivacy.own
                updated.append(reserved)
            }
            let index = updated.firstIndex(where:{ $0.server == host })!
            var settings = updated[index].serverSettings ?? OwnerServerSettings()
            settings.accessCode = accessCode.trimmingCharacters(in:.whitespacesAndNewlines)
            if token != nil { settings.pendingAccount = OwnerAccountLinkIntent(email:mail) }
            try settings.validate(); updated[index].serverSettings = settings
            try saveOwners(updated)
            if owners[index].credentials == nil {
                return await registerReservedOwner(host,accessCode:settings.accessCode,accountToken:token,suiteChecked:true)
            }
            if let token { return await changeServerAccount(host,email:mail,token:token) }
            await syncOwner(host)
            return true
        } catch { errorMessage = ProductText.string(mail.isEmpty ? "server_add_failed" : "server_account_failed"); return false }
    }

    private func changeServerAccount(_ host: String,email: String?,token: String?) async -> Bool {
        guard let index = owners.firstIndex(where:{ $0.server == host }), let credentials = owners[index].credentials else { return false }
        do {
            var updated = owners
            var settings = updated[index].serverSettings ?? OwnerServerSettings()
            var intent = OwnerAccountLinkIntent(email:email); intent.sent = true
            settings.pendingAccount = intent; try settings.validate(); updated[index].serverSettings = settings
            try saveOwners(updated)
            let confirmed = try await ownerAPI.linkAccount(server:host,credentials:credentials,token:token)
            guard confirmed?.lowercased() == email?.lowercased(),
                  let current = owners.firstIndex(where:{ $0.server == host && $0.credentials == credentials }) else { throw GuestCrypto.Failure.invalidEnvelope }
            updated = owners
            updated[current].serverSettings?.accountEmail = confirmed
            updated[current].serverSettings?.pendingAccount = nil
            try saveOwners(updated)
            await syncOwner(host)
            return true
        } catch { errorMessage = ProductText.string("ios_server_account_uncertain"); return false }
    }
    func unlinkServerAccount(_ host: String) async -> Bool {
        guard canManageGuestAccess, !ownerBusy, !busy else { return false }
        ownerBusy = true; defer { ownerBusy = false }
        return await changeServerAccount(host,email:nil,token:nil)
    }
}

extension AppModel {
    func receiveCompanyInvite(_ invite: CompanyInvite) async {
        guard canManageGuestAccess, !companyBusy, !ownerBusy, !busy else { return }
        companyBusy = true; defer { companyBusy = false }
        let prior = companies
        do {
            var profile = try await ownerAPI.companyInvite(server:invite.server,code:invite.code)
            guard canManageGuestAccess, profile.server == invite.server, profile.pendingCode == invite.code else { throw GuestCrypto.Failure.invalidEnvelope }
            if let old = companies.first(where:{ $0.id == profile.id }) {
                if profile.logo?.isEmpty != false { profile.logo = old.logo }
            }
            if let index = companies.firstIndex(where:{ $0.id == profile.id }) { companies[index] = profile }
            else { companies.append(profile) }
            try KnownCompany.validateDirectory(companies)
            var updated = owners
            if let index = updated.firstIndex(where:{ $0.server == profile.server }) {
                // Prefs.setOrgKnownPub: deliberately opening a NEW company
                // request updates that company's issued pins. Ordinary owner
                // sync/profile branding must never take this path.
                if let publicKey = profile.publicKey {
                    for offset in (updated[index].issuedKeys ?? []).indices where updated[index].issuedKeys![offset].company?.companyID == profile.companyID {
                        updated[index].issuedKeys![offset].company?.publicKey = publicKey
                    }
                }
            }
            try saveOwners(updated)
            companyRequestID = profile.id
            // Android marks arrival only after the request is stored, and only
            // with credentials belonging to this exact server. No registration.
            if let credentials = owners.first(where:{ $0.server == invite.server })?.credentials {
                try? await ownerAPI.companyClaim(server:invite.server,credentials:credentials,code:invite.code)
            }
        } catch {
            companies = prior
            errorMessage = "Не удалось сохранить запрос компании. Доступ не выдавался."
        }
    }
    func companyKeys(_ company: KnownCompany) -> [OwnerIssuedKey] {
        owners.first(where:{ $0.server == company.server })?.issuedKeys?.filter { $0.company?.companyID == company.companyID && $0.state != .revoked } ?? []
    }
    func issueCompanyAccess(profileID: String, numberIDs: [Int], calls: [String:OwnerCallPreference]) async -> Bool {
        guard canManageGuestAccess, !ownerBusy, !busy, let company = companies.first(where:{ $0.id == profileID }),
              owners.contains(where:{ $0.server == company.server && $0.credentials != nil }) else { return false }
        ownerBusy = true; defer { ownerBusy = false }
        do {
            // Avoid the API's implicit merge into an unknown signing identity.
            await syncOwner(company.server)
            guard canManageGuestAccess, ownerMessages[company.server] == nil, let snapshot = ownerSnapshots[company.server],
                  !snapshot.keyRows.contains(where:{ $0["org_id"] as? Int == company.companyID && ($0["enabled"] as? Int) != 0 }),
                  let currentIndex = owners.firstIndex(where:{ $0.server == company.server }) else {
                errorMessage = "У компании уже есть доступ. Откройте его настройки; если ключа нет на телефоне, восстановите резервную копию."; return false
            }
            var authority = owners[currentIndex]; authority.reservedGuestIDs = allReservedGuestIDs()
            let key = try OwnerIssuedKey.forCompany(owner:authority,profile:company,numberIDs:numberIDs,calls:calls)
            var updated = owners
            updated[currentIndex].reservedGuestIDs = authority.reservedGuestIDs
            updated[currentIndex].issuedKeys = (updated[currentIndex].issuedKeys ?? []) + [key]
            try saveOwners(updated)
            return await sendOwnerKey(server:company.server,keyID:key.id)
        } catch { errorMessage = "Не удалось сохранить доступ компании. Выберите сохранённые объекты для звонка."; return false }
    }
    func forgetCompany(_ id: String) async {
        guard canManageGuestAccess, !companyBusy, !ownerBusy, !busy, let company = companies.first(where:{ $0.id == id }) else { return }
        companyBusy = true; defer { companyBusy = false }
        for key in companyKeys(company) {
            guard key.keyID != nil else {
                if !key.sent { discardUnsentOwnerKey(server:company.server,keyID:key.id); continue }
                errorMessage = "Сначала проверьте результат незавершённой выдачи компании."; return
            }
            await revokeOwnerKey(server:company.server,keyID:key.id)
        }
        guard companyKeys(company).isEmpty else { errorMessage = "Отзыв доступа компании ещё не подтверждён. Обновите данные и повторите удаление."; return }
        let prior = companies
        companies.removeAll { $0.id == id }
        do { try save(guests) } catch { companies = prior; errorMessage = "Не удалось сохранить удаление компании." }
    }
}

extension AppModel {
    @discardableResult func saveGuestDefaults(_ defaults: OwnerGuestDefaults) -> Bool {
        guard canManageGuestAccess else { return false }
        let previous = ownerGuestDefaults
        do {
            try defaults.validate()
            var updated = owners
            if defaults.ownerName != previous.ownerName {
                for index in updated.indices {
                    updated[index].hostLabel = defaults.ownerName
                    for key in updated[index].issuedKeys ?? [] { updated[index].queueKeySettings(key.id) }
                }
            }
            ownerGuestDefaults = defaults
            try saveOwners(updated)
            return true
        } catch { ownerGuestDefaults = previous; errorMessage = "Не удалось сохранить пресеты гостей."; return false }
    }
    func canCloneOwnerKey(server: String, keyID: UUID) -> Bool {
        guard let owner = owners.first(where:{ $0.server == server }),
              let key = owner.issuedKeys?.first(where:{ $0.id == keyID }), key.company == nil, key.pending == nil,
              [.active,.paused,.restricted].contains(key.state), key.accessNeedsReview != true else { return false }
        return !(owner.issuedKeys ?? []).contains { $0.cloneSourceID == keyID && $0.pending == .keyCreate }
    }
    func cloneOwnerKey(server: String, keyID: UUID) async {
        guard canManageGuestAccess, !busy, !ownerBusy, canCloneOwnerKey(server:server,keyID:keyID),
              let index = owners.firstIndex(where:{ $0.server == server }), let source = owners[index].issuedKeys?.first(where:{ $0.id == keyID }) else { return }
        ownerBusy = true; defer { ownerBusy = false }
        do {
            let suffix = ProductText.string("guest_key_copy_suffix")
            let label = source.label.isEmpty ? suffix : source.label+" ("+suffix+")"
            let clone = try source.cloned(owner:owners[index],label:label)
            var updated = owners; updated[index].issuedKeys = (updated[index].issuedKeys ?? [])+[clone]
            try saveOwners(updated)
            _ = await sendOwnerKey(server:server,keyID:clone.id)
        } catch { errorMessage = "Не удалось сохранить копию ключа. Новая выдача не подтверждена." }
    }
}
