import Foundation
import Combine
import EntrixyCore

@MainActor
final class DelegationInbox: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var preview: DelegationRedemption?
    @Published private(set) var message: String?
    private unowned let app: AppModel
    private let api: DelegationTransport
    private var generation = UUID()
    private let automaticUpdates: Bool
    private var worker: Task<Void, Never>?
    private var infoCursor = 0
    private var checkCursor = 0
    private var partCursors: [String: Int] = [:]
    init(app: AppModel, api: DelegationTransport = GuestAPI(), automaticUpdates: Bool = true) {
        self.app = app; self.api = api; self.automaticUpdates = automaticUpdates
    }
    deinit { worker?.cancel() }
    func resume() {
        guard automaticUpdates, worker == nil, app.canManageGuestAccess,
              !app.delegations.isEmpty || !app.receivedDelegations.isEmpty else { return }
        let model = app
        worker = Task { [weak self, weak model] in
            var tick = 0
            while !Task.isCancelled {
                guard let model, model.canManageGuestAccess else { return }
                if tick % 4 == 0 { await self?.refreshAdditionalParts() }
                await self?.checkAll()
                tick += 1
                guard model.canManageGuestAccess else { return }
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
    }
    func suspend() { generation = UUID(); worker?.cancel(); worker = nil }
    func discardGroups(_ ids: Set<String>) {
        suspend()
        if let current = preview, ids.contains(current.id) { preview = nil }
        for id in ids { partCursors.removeValue(forKey: id) }
        resume()
    }
    func clearPreview() { generation = UUID(); preview = nil; message = nil }
    func inspect(_ text: String) async {
        guard !busy, app.canManageGuestAccess else { return }
        busy = true; preview = nil; message = nil
        let current = generation
        defer { busy = false }
        do {
            let link = try DelegationLink.parse(text)
            guard !app.delegations.contains(where: { $0.id == link.id }) else {
                message = "Эта передача уже сохранена. Проверьте её в Настройках → Ожидаемые ключи."; return
            }
            let info = try await api.delegationInfo(server: link.server, group: link.group)
            guard !Task.isCancelled, generation == current, app.canManageGuestAccess else { return }
            var received = app.receivedDelegations.first { $0.id == link.id }
            guard received == nil || received?.link.secret == link.secret else { throw BackupFailure.conflictingAccess }
            if let record = received, !(record.importedGuestIDs ?? []).isEmpty, record.importedBaselineCodes == nil {
                try app.rememberImportedDelegationCodes(record.id, codes: DelegationRedemption.redeemedCodes(info: info, group: link.group))
                received = app.receivedDelegations.first { $0.id == link.id }
            }
            let legacyMembers = app.guests.filter { $0.keyGroup == link.id && $0.incomingRecipient != nil }
            let legacyPending = app.androidPendingGuests.filter { $0.groupID == link.id && $0.recipient != nil }
            let pairs = legacyMembers.compactMap(\.incomingRecipient) + legacyPending.compactMap(\.recipient)
            let pair = received?.recipient ?? pairs.first
            guard pairs.allSatisfy({ $0.publicKey == pair?.publicKey && $0.privateKey == pair?.privateKey }) else { throw BackupFailure.conflictingAccess }
            let importedIDs = received?.importedGuestIDs ?? (legacyMembers.map(\.id) + legacyPending.map(\.id))
            let baseline: [String]
            if let stored = received?.importedBaselineCodes { baseline = stored }
            else if importedIDs.isEmpty { baseline = [] }
            else { baseline = try DelegationRedemption.redeemedCodes(info: info, group: link.group) }
            let installed = Set(received?.parts.filter { part in app.guests.contains(where: { $0.id == part.guestID }) }.map(\.code) ?? []).union(baseline)
            let offered = try DelegationRedemption.availableCodes(info: info, group: link.group)
            guard offered.contains(where: { !installed.contains($0) }) else {
                message = received == nil ? "В этой передаче сейчас нет доступных частей." : "Эта передача уже установлена. Новых частей пока нет."; return
            }
            let pending = try DelegationRedemption(link: link, info: info, recipient: pair, excludingCodes: installed,
                                                  importedGuestIDs: importedIDs, importedBaselineCodes: baseline)
            if generation == current { preview = pending }
        } catch { if generation == current { message = "Не удалось проверить передачу. Ссылка могла истечь или сервер недоступен." } }
    }
    func accept() async {
        guard !busy, app.canManageGuestAccess, let pending = preview else { return }
        do { try app.reserveDelegation(pending) }
        catch { message = "Не удалось сохранить передачу. Запрос принятия не отправлялся."; return }
        preview = nil
        await send(pending.id)
    }
    func send(_ id: String) async {
        guard !busy, app.canManageGuestAccess, let pending = app.delegations.first(where: { $0.id == id }), !pending.sent else { return }
        busy = true; message = nil
        defer { busy = false; resume() }
        await submitSaved(id)
        await resolveSaved(id)
    }
    private func submitSaved(_ id: String) async {
        guard app.canManageGuestAccess, let pending = app.delegations.first(where: { $0.id == id }), !pending.sent else { return }
        do { try app.markDelegationSent(id) }
        catch { message = "Не удалось сохранить передачу. Запрос принятия не отправлялся; можно повторить сохранение."; return }
        do {
            guard let saved = app.delegations.first(where: { $0.id == id }) else { throw BackupFailure.invalidPayload }
            let response = try await api.redeemDelegation(saved, fingerprint: app.backupFingerprint(server: saved.link.server))
            guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  (json["ok"] as? NSNumber)?.boolValue == true else { throw BackupFailure.invalidPayload }
            message = "Запрос принят. Ключи появятся после подтверждения владельцами."
        } catch {
            message = "Ответ принятия не подтверждён. Данные получателя сохранены; повторное принятие не отправляется."
        }
    }
    func check(_ id: String) async {
        guard !busy, app.canManageGuestAccess else { return }
        busy = true; message = nil
        defer { busy = false }
        await resolveSaved(id)
    }
    func checkAll() async {
        guard !busy, app.canManageGuestAccess else { return }
        busy = true
        defer { busy = false }
        for id in Self.batch(app.delegations.map(\.id), cursor: &checkCursor, maximum: 2) { await resolveSaved(id, maximumParts: 1) }
    }
    private func resolveSaved(_ id: String, maximumParts: Int = 4) async {
        guard let pending = app.delegations.first(where: { $0.id == id }) else { return }
        let currentGeneration = generation
        guard pending.sent else { message = "Принятие ещё не отправлялось. Данные сохранены на этом iPhone."; return }
        var unavailable = false
        var cursor = partCursors[id] ?? 0
        let parts = Self.batch(pending.parts.filter { !pending.completedCodes.contains($0.code) }, cursor: &cursor, maximum: maximumParts)
        partCursors[id] = cursor
        for part in parts {
            guard app.canManageGuestAccess else { return }
            do {
                let fp = try app.backupFingerprint(server: pending.link.server)
                if let invite = try await api.resolveDelegation(pending, part: part, fingerprint: fp) {
                    guard !Task.isCancelled, generation == currentGeneration, app.canManageGuestAccess,
                          app.delegations.contains(where: { $0.id == id && $0.link == pending.link
                            && $0.recipient.publicKey == pending.recipient.publicKey
                            && $0.parts.contains(where: { $0.code == part.code && $0.userKey == part.userKey }) }) else { return }
                    try app.installDelegatedInvite(invite, pendingID: id, code: part.code)
                    if automaticUpdates { app.connectInstalledGuest(invite.id) }
                } else { unavailable = true }
            } catch is URLError { unavailable = true; break }
            catch let error as GuestAPI.Failure where error.status == 429 || error.status >= 500 { unavailable = true; break }
            catch { unavailable = true }
        }
        unavailable = unavailable || app.delegations.contains(where: { $0.id == id })
        message = unavailable ? "Часть ключей пока не готова или сервер недоступен. Подтверждённые доступы сохранены. Повторного принятия не было."
            : "Подтверждённые ключи сохранены. Обновите Управление, чтобы получить объекты."
    }
    private static func batch<T>(_ rows: [T], cursor: inout Int, maximum: Int) -> [T] {
        guard !rows.isEmpty else { cursor = 0; return [] }
        let count = min(maximum, rows.count), start = cursor % rows.count
        cursor = (start + count) % rows.count
        return (0..<count).map { rows[(start + $0) % rows.count] }
    }
    func refreshAdditionalParts() async {
        guard !busy, app.canManageGuestAccess else { return }
        let currentGeneration = generation
        busy = true
        defer { busy = false }
        for receipt in Self.batch(app.receivedDelegations, cursor: &infoCursor, maximum: 8) {
            guard app.canManageGuestAccess else { return }
            guard !app.delegations.contains(where: { $0.id == receipt.id }) else { continue }
            do {
                let info = try await api.delegationInfo(server: receipt.link.server, group: receipt.link.group)
                guard !Task.isCancelled, generation == currentGeneration, app.canManageGuestAccess,
                      let latest = app.receivedDelegations.first(where: { $0.id == receipt.id && $0.link == receipt.link
                        && $0.recipient.publicKey == receipt.recipient.publicKey && $0.recipient.privateKey == receipt.recipient.privateKey }) else { return }
                var baseline = latest.importedBaselineCodes ?? []
                if !(latest.importedGuestIDs ?? []).isEmpty, latest.importedBaselineCodes == nil {
                    baseline = try DelegationRedemption.redeemedCodes(info: info, group: latest.link.group)
                    try app.rememberImportedDelegationCodes(latest.id, codes: baseline)
                }
                let installed = Set(latest.parts.filter { part in app.guests.contains(where: { $0.id == part.guestID }) }.map(\.code)).union(baseline)
                let offered = try DelegationRedemption.availableCodes(info: info, group: receipt.link.group)
                guard offered.contains(where: { !installed.contains($0) }) else { continue }
                let pending = try DelegationRedemption(link: receipt.link, info: info, recipient: receipt.recipient, excludingCodes: installed,
                                                      importedGuestIDs: latest.importedGuestIDs ?? [], importedBaselineCodes: baseline)
                try app.reserveDelegation(pending)
                await submitSaved(pending.id)
            } catch { message = "Не удалось проверить новые части передачи. Установленные ключи сохранены." }
        }
    }
}
