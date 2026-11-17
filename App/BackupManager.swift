import Foundation
import Combine
import EntrixyCore

/// A different payload identifier prevents Android from applying unknown iOS entries as an empty backup.
struct IOSBackupPayload: Codable {
    let app: String
    let version: Int
    let created: Date
    let sourceIdentity: Data
    let owners: [OwnerAccount]
    let guests: [SavedGuest]
    let journal: [JournalEntry]
    let usedOwnerPresses: [String: Date]
    let passedAccess: [PassedAccess]?
    let receivedDelegations: [ReceivedDelegation]?
    let incomingMessages: [SavedMessage]?
    let outgoingMessages: [OutgoingMessage]?
    let delegatedJournalLedger: DelegatedJournalLedger?
    let ownerGuestDefaults: OwnerGuestDefaults?
    let companies: [KnownCompany]?
    let androidArchives: [AndroidBackupDocument]?
    /// Present only in a normalized Android import, never in a later iOS
    /// export. Original archives remain preserved separately for unmapped data.
    let androidGuests: [AndroidGuestMigration]?
    let objectPreferences: ObjectCatalogPreferences?
    init(state: SavedState, created: Date = Date(), androidGuests: [AndroidGuestMigration]? = nil) {
        app = "entrixy-ios"; version = 1; self.created = created; sourceIdentity = state.identity
        owners = state.owners ?? []; guests = state.guests
        journal = (state.journal ?? []).filter(\.isAction)
        usedOwnerPresses = state.usedOwnerPresses ?? [:]
        passedAccess = state.passedAccess
        receivedDelegations = state.receivedDelegations
        incomingMessages = state.incomingMessages
        outgoingMessages = state.outgoingMessages
        delegatedJournalLedger = state.delegatedJournalLedger
        objectPreferences = state.objectPreferences
        ownerGuestDefaults = state.ownerGuestDefaults
        companies = state.companies
        androidArchives = state.androidArchives
        self.androidGuests = androidGuests ?? state.androidPendingGuests?.map { source in
            var exported = source
            // This pending identity was already moved to the exporting iPhone.
            // A later migration must sign with THAT device, not the old Android.
            exported.oldFingerprint = GuestCrypto.hash(state.identity + Data(source.identity.server.utf8))
            return exported
        }
    }
    init(android document: AndroidBackupDocument) throws {
        let owners = try AndroidOwnerAdapter.owners(from:document)
        let migrations = try document.guestMigrations()
        // Provenance digest, NOT a replacement installation identity or an
        // Android device fingerprint. Android migrations carry their real old
        // per-server fingerprint and never use sourceIdentity for authorization.
        let hash = document.archiveID
        let provenance = Data(stride(from:0,to:64,by:2).map { UInt8(hash.dropFirst($0).prefix(2),radix:16)! })
        let state = SavedState(identity:provenance,guests:[],owners:owners,ownerGuestDefaults:try document.guestDefaults(),companies:try document.companies(),androidArchives:[document])
        self.init(state:state,created:document.created,androidGuests:migrations)
    }
    func validate() throws {
        try ownerGuestDefaults?.validate()
        try KnownCompany.validateDirectory(companies ?? [])
        try AndroidBackupDocument.validateArchives(androidArchives ?? [])
        let android = androidGuests ?? []
        guard android.count <= 1000, Set(android.map(\.id)).count == android.count,
              Set(android.map(\.id)).isDisjoint(with:Set(guests.map(\.id))) else { throw BackupFailure.invalidPayload }
        for guest in android { try guest.validate() }
        try objectPreferences?.validate()
        try delegatedJournalLedger?.validate()
        guard app == "entrixy-ios", version == 1, sourceIdentity.count == 32, owners.count <= 100,
              (!owners.isEmpty || !guests.isEmpty || !android.isEmpty || !(passedAccess ?? []).isEmpty), guests.count <= 1000, journal.count <= 500, usedOwnerPresses.count <= 2048,
              created.timeIntervalSinceReferenceDate.isFinite,
              Set(journal.map(\.id)).count == journal.count,
              journal.allSatisfy({ $0.isAction && $0.date.timeIntervalSinceReferenceDate.isFinite }),
              usedOwnerPresses.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 512 && $0.value.timeIntervalSinceReferenceDate.isFinite }),
              Set(owners.map(\.server)).count == owners.count, Set(guests.map(\.id)).count == guests.count else { throw BackupFailure.invalidPayload }
        let receipts = receivedDelegations ?? []
        guard receipts.count <= 1000, Set(receipts.map(\.id)).count == receipts.count else { throw BackupFailure.invalidPayload }
        let guestIDs = Set(guests.map(\.id))
        let incoming = incomingMessages ?? [], outgoing = outgoingMessages ?? []
        guard incoming.count <= 200, outgoing.count <= 100,
              Set(incoming.map(\.id)).count == incoming.count, Set(outgoing.map(\.id)).count == outgoing.count else { throw BackupFailure.invalidPayload }
        for row in incoming { try row.validate(); guard guestIDs.contains(row.guestID) else { throw BackupFailure.invalidPayload } }
        for row in outgoing { try row.validate() }
        for receipt in receipts {
            try receipt.validate()
            guard Set(receipt.parts.map(\.guestID)).isSubset(of: guestIDs) else { throw BackupFailure.invalidPayload }
        }
        let passed = passedAccess ?? []
        guard passed.count <= 500, Set(passed.map(\.id)).count == passed.count else { throw BackupFailure.invalidPayload }
        for record in passed { try record.validate() }
        for owner in owners {
            try owner.validate()
            for move in owner.bleMoves ?? [] {
                guard owners.contains(where: { $0.server == move.destination && $0.credentials != nil }) else { throw BackupFailure.invalidPayload }
            }
        }
        for guest in guests {
            try guest.validateObjectSettings()
            _ = try guest.bleCache?.open(key: guest.invite.bundleKey)
            let link = "https://\(guest.invite.server)/key#\(guest.invite.userKey)\(GuestCrypto.base64URL(guest.invite.bundleKey))"
            guard try GuestInvite.parse(link) == guest.invite else { throw BackupFailure.invalidPayload }
        }
    }
}

struct BackupRestorePlan: Codable {
    let payload: IOSBackupPayload
    var preflightDone = false
    var restoredOwners: [String] = []
    var restoredGuests: [String] = []
    var movedAndroidGuests: [String]? = nil
    var restoredAndroidGuests: [String]? = nil
    func validate() throws {
        try payload.validate()
        let androidIDs = Set((payload.androidGuests ?? []).map(\.id))
        guard Set(movedAndroidGuests ?? []).count == (movedAndroidGuests ?? []).count,
              Set(restoredAndroidGuests ?? []).count == (restoredAndroidGuests ?? []).count,
              Set(movedAndroidGuests ?? []).isSubset(of:androidIDs),
              Set(restoredAndroidGuests ?? []).isSubset(of:Set(movedAndroidGuests ?? [])) else { throw BackupFailure.invalidPayload }
        guard Set(restoredOwners).count == restoredOwners.count,
              Set(restoredGuests).count == restoredGuests.count,
              Set(restoredOwners).isSubset(of: Set(payload.owners.map(\.server))),
              Set(restoredGuests).isSubset(of: Set(payload.guests.map(\.id))) else { throw BackupFailure.invalidPayload }
    }
}

enum BackupFailure: Error {
    case invalidPayload, conflictingAccess, noAccess, busy, pendingAccess
}

@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var preview: IOSBackupPayload?
    @Published private(set) var exportData: Data?
    private(set) var exportMaterialIDs = Set<String>()
    @Published private(set) var remainingOwners = 0
    @Published private(set) var remainingGuests = 0
    @Published private(set) var importMessages: [String:String] = [:]
    private unowned let app: AppModel
    private let guestMover: GuestMigrationTransport
    private let refreshAfterRestore: Bool
    var hasPendingRestore: Bool { app.backupPlan() != nil }
    init(app: AppModel, guestMover: GuestMigrationTransport = GuestAPI(), refreshAfterRestore: Bool = true) {
        self.app = app; self.guestMover = guestMover; self.refreshAfterRestore = refreshAfterRestore
        updateProgress()
    }
    func makePresentation() -> BackupPresentation { BackupPresentation(app:app,manager:self) }

    func export(password: String) async throws -> Data {
        guard !busy else { throw BackupFailure.busy }
        busy = true; message = nil
        defer { busy = false }
        let state = try app.backupState()
        guard !(state.owners ?? []).isEmpty || !state.guests.isEmpty || !(state.passedAccess ?? []).isEmpty || !(state.androidPendingGuests ?? []).isEmpty else { throw BackupFailure.noAccess }
        let payload = IOSBackupPayload(state: state)
        try payload.validate()
        let bytes = try JSONEncoder().encode(payload)
        let encrypted = try await Task.detached(priority: .userInitiated) { try BackupEnvelope.seal(bytes, password: password) }.value
        exportData = encrypted
        exportMaterialIDs = state.backupMaterialIDs
        return encrypted
    }

    func inspect(_ bytes: Data, password: String) async throws {
        guard !hasPendingRestore else { throw BackupFailure.busy }
        guard !busy else { throw BackupFailure.busy }
        busy = true; preview = nil; message = nil
        defer { busy = false }
        let plain = try await Task.detached(priority: .userInitiated) { try BackupEnvelope.open(bytes, password: password) }.value
        guard let header = try JSONSerialization.jsonObject(with:plain) as? [String:Any] else { throw BackupFailure.invalidPayload }
        let payload: IOSBackupPayload
        switch header["app"] as? String {
        case "entrixy-ios": payload = try JSONDecoder().decode(IOSBackupPayload.self,from:plain)
        case "entrixy": payload = try IOSBackupPayload(android:AndroidBackupDocument(plain))
        default: throw BackupFailure.invalidPayload
        }
        try payload.validate()
        guard try JSONEncoder().encode(payload).count <= BackupEnvelope.maxPayloadSize else { throw BackupFailure.invalidPayload }
        try app.validateRestoreConflicts(payload)
        preview = payload
    }

    func restore() async {
        guard !busy else { return }
        do {
            if app.backupPlan() == nil {
                guard let payload = preview else { return }
                try app.validateRestoreConflicts(payload)
                // The complete source credentials are durable before any server-side move.
                try app.saveBackupPlan(BackupRestorePlan(payload: payload))
            }
            try app.beginBackupRestore()
        } catch { message = "Не удалось сохранить план переноса. Серверные запросы не отправлялись."; return }
        busy = true; message = nil
        defer { busy = false; app.endBackupRestore(refresh: refreshAfterRestore); updateProgress() }
        guard var plan = app.backupPlan() else { return }
        do {
            try app.validateRestoreConflicts(plan.payload)
            // Re-check remaining owners on every explicit resume as well.
            for owner in plan.payload.owners where owner.credentials != nil && !plan.restoredOwners.contains(owner.server) {
                try await app.claimBackupOwner(owner, dryRun: true)
            }
            plan.preflightDone = true
            try app.saveBackupPlan(plan)
            for owner in plan.payload.owners where !plan.restoredOwners.contains(owner.server) {
                if owner.credentials != nil { try await app.claimBackupOwner(owner, dryRun: false) }
                plan.restoredOwners.append(owner.server)
                // Access and its checkpoint are committed together; other servers stay untouched.
                try app.activateBackupOwner(owner, plan: plan)
                updateProgress()
            }
            for guest in plan.payload.guests where !plan.restoredGuests.contains(guest.id) {
                let old = try MigrationFingerprint.ios(identity: plan.payload.sourceIdentity, server: guest.invite.server)
                let new = try app.backupFingerprint(server: guest.invite.server)
                try await guestMover.move(invite: guest.invite, oldFingerprint: old, newFingerprint: new)
                plan.restoredGuests.append(guest.id)
                try app.activateBackupGuest(guest, plan: plan)
                updateProgress()
            }
            for source in plan.payload.androidGuests ?? [] where !(plan.restoredAndroidGuests ?? []).contains(source.id) {
                let newFingerprint = try app.backupFingerprint(server:source.identity.server)
                if !(plan.movedAndroidGuests ?? []).contains(source.id) {
                    try await guestMover.move(identity:source.identity,oldFingerprint:source.oldFingerprint,newFingerprint:newFingerprint)
                    plan.movedAndroidGuests = (plan.movedAndroidGuests ?? []) + [source.id]
                    try app.saveBackupPlan(plan)
                }
                let invite = try await guestMover.recover(identity:source.identity,bundleKey:source.bundleKey,recipient:source.recipient,fingerprint:newFingerprint)
                guard invite == nil || invite?.id == source.id else { throw BackupFailure.invalidPayload }
                plan.restoredAndroidGuests = (plan.restoredAndroidGuests ?? []) + [source.id]
                if let invite { try app.activateBackupGuest(SavedGuest(invite:invite,requiresBLEExitOnRestore:true),plan:plan) }
                else { try app.activatePendingAndroidGuest(source,plan:plan) }
                updateProgress()
            }
            try app.finishBackupRestore(plan)
            preview = nil
            message = app.androidPendingGuests.isEmpty
                ? "Доступы перенесены на этот iPhone. Старый телефон больше не может использовать перенесённые привязки."
                : "Привязки перенесены. Ключей, ожидающих защищённую связку от владельца: \(app.androidPendingGuests.count). Они сохранены в разделе «Ключи»."
        } catch {
            // The saved plan retains old-device proofs if a later server or a write failed.
            let code = (error as? OwnerAPI.Failure)?.code ?? (error as? GuestAPI.Failure)?.code
            message = code == "move_too_soon"
                ? "Сервер пока запрещает повторный перенос устройства. План сохранён; продолжите после окончания ограничения."
                : "Перенос не завершён. Уже перенесённые доступы сохранены; оставшиеся можно перенести кнопкой «Продолжить»."
        }
    }
    func clearPreview() { preview = nil; message = nil }
    func recoverImportedGuest(_ id: String) async {
        guard !busy, app.canManageGuestAccess, let source = app.androidPendingGuests.first(where:{ $0.id == id }) else { return }
        busy = true; defer { busy = false }; importMessages.removeValue(forKey:id)
        do {
            let fingerprint = try app.backupFingerprint(server:source.identity.server)
            guard let invite = try await guestMover.recover(identity:source.identity,bundleKey:source.bundleKey,recipient:source.recipient,fingerprint:fingerprint) else {
                importMessages[id] = ProductText.string("guests_key_awaiting_bundle"); return
            }
            try app.acceptRecoveredAndroidGuest(invite)
        } catch { importMessages[id] = "Связка пока не подтверждена. Исходный ключ и данные получателя сохранены." }
    }
    func refreshImportedGuests() async {
        for source in app.androidPendingGuests { await recoverImportedGuest(source.id) }
    }
    func clearExport() { exportData = nil; exportMaterialIDs = [] }
    func report(_ error: Error) {
        switch error {
        case BackupEnvelope.Failure.passwordOrDamage: message = "Неверный пароль или файл повреждён. Доступы не изменялись."
        case BackupEnvelope.Failure.invalidPassword: message = "Используйте пароль не короче 8 символов."
        case BackupFailure.pendingAccess: message = "Сначала завершите приём ожидаемых ключей в Настройках. Их незавершённые данные пока нельзя перенести в копии."
        case BackupFailure.noAccess: message = "Пока нет доступов для сохранения."
        case BackupFailure.conflictingAccess: message = "На этом iPhone уже есть другая привязка к одному из серверов. Ничего не заменено."
        case BackupFailure.busy: message = "Сначала завершите текущую операцию или сохранённый перенос."
        default: message = "Не удалось прочитать копию или её формат не поддерживается. Доступы не изменялись."
        }
    }
    func updateProgress() {
        guard let plan = app.backupPlan() else { remainingOwners = 0; remainingGuests = 0; return }
        remainingOwners = plan.payload.owners.count - plan.restoredOwners.count
        remainingGuests = plan.payload.guests.count - plan.restoredGuests.count + (plan.payload.androidGuests ?? []).count - (plan.restoredAndroidGuests ?? []).count
    }
}
