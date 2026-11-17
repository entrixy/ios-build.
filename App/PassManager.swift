import Foundation
import Combine
import EntrixyCore

@MainActor
final class PassManager: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var snapshots: [String: PassSnapshot] = [:]
    @Published private(set) var message: String?
    private unowned let app: AppModel
    private let api: DelegationTransport
    private var pendingSaves: [UUID: PassedAccess] = [:]
    init(app: AppModel, api: DelegationTransport = GuestAPI()) { self.app = app; self.api = api }
    func reload(sourceID: String? = nil) async {
        guard !busy, app.canManageGuestAccess else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try flushSaves()
            for guest in app.guests where sourceID == nil || guest.id == sourceID {
                do { try await sync(guest) }
                catch { message = "Часть данных передачи не обновлена. Сохранённые ссылки и секреты остаются на этом iPhone." }
            }
        } catch { message = "Полученный ответ пока не сохранён. Повторите сохранение; запрос выдачи не отправляется повторно." }
    }
    private func sync(_ guest: SavedGuest) async throws {
        guard app.canManageGuestAccess else { throw BackupFailure.busy }
        let fp = try app.backupFingerprint(server: guest.invite.server)
        let bytes = try await api.delegate(invite: guest.invite, fingerprint: fp, operation: .list, body: Data("{}".utf8))
        let snapshot = try PassSnapshot.decode(bytes)
        try app.importDelegatedJournal(snapshot.journal, sourceID: guest.id)
        snapshots[guest.id] = snapshot
        for var record in app.passedAccess where record.parts.contains(where: { $0.sourceID == guest.id }) {
            try record.reconcile(snapshot, sourceID: guest.id)
            try saveReply(record)
            guard app.canManageGuestAccess else { return }
            let vouches = try record.vouches(snapshot: snapshot, invite: guest.invite)
            if let group = record.group,
               snapshot.children.contains(where: { $0.group == group && !$0.vouched }), vouches.isEmpty,
               !record.parts.contains(where: { $0.sourceID == guest.id && [.revoking, .revoked].contains($0.state) }) {
                message = "Проверка получателя пока не прошла. Поручительство за непроверенный ключ не отправлялось."
            }
            for body in vouches {
                guard app.canManageGuestAccess else { return }
                _ = try await api.delegate(invite: guest.invite, fingerprint: fp, operation: .vouch, body: body)
            }
        }
    }
    private func flushSaves() throws {
        for (id, record) in pendingSaves {
            try app.savePassedAccess(record); pendingSaves.removeValue(forKey: id)
        }
    }
    private func saveReply(_ record: PassedAccess) throws {
        do { try app.savePassedAccess(record); pendingSaves.removeValue(forKey: record.id) }
        catch { pendingSaves[record.id] = record; throw error }
    }
    func create(label: String, welcome: String, objects: [String: [Int: KeyObjectAccess]]) async -> UUID? {
        guard !busy, app.canManageGuestAccess, !app.busy, !app.ownerBusy else { return nil }
        busy = true; message = nil
        defer { busy = false }
        var savedID: UUID?
        do {
            try flushSaves()
            let sources = try objects.keys.map { source -> SavedGuest in
                guard let guest = app.guests.first(where: { $0.id == source && !$0.paused }) else { throw BackupFailure.noAccess }; return guest
            }
            guard let server = sources.first?.invite.server, sources.allSatisfy({ $0.invite.server == server }) else { throw BackupFailure.conflictingAccess }
            for guest in sources { try await sync(guest) }
            let record = try PassedAccess(server:server,label:label,welcome:welcome,objects:objects,snapshots:snapshots,from:app.ownerGuestDefaults.ownerName)
            try app.savePassedAccess(record)
            savedID = record.id
            try await submitUnsent(record.id)
        } catch { message = savedID == nil ? "Не удалось сохранить передачу. Новая ссылка не запрашивалась." : "Передача сохранена, но результат не подтверждён. Проверьте данные; повторной выдачи не было." }
        return savedID
    }
    func continueCreating(_ id: UUID) async {
        guard !busy, app.canManageGuestAccess else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try flushSaves()
            guard let record = app.passedAccess.first(where: { $0.id == id }) else { return }
            for source in record.parts {
                guard let guest = app.guests.first(where: { $0.id == source.sourceID }) else { throw BackupFailure.noAccess }
                try await sync(guest)
            }
            try await submitUnsent(id)
        } catch { message = "Не удалось завершить передачу. Сохранённые данные и неопределённые ответы не заменены новой ссылкой." }
    }
    private func submitUnsent(_ id: UUID) async throws {
        guard let initial = app.passedAccess.first(where: { $0.id == id }) else { return }
        for index in initial.parts.indices {
            guard app.canManageGuestAccess, var record = app.passedAccess.first(where: { $0.id == id }) else { throw BackupFailure.busy }
            let part = record.parts[index]
            guard part.state == .draft else { continue }
            guard !part.sent else { message = "Результат выдачи пока не подтверждён. Обновление проверяет сервер без повторной выдачи."; return }
            guard let guest = app.guests.first(where: { $0.id == part.sourceID && !$0.paused }),
                  guest.invite.server == record.server else { throw BackupFailure.noAccess }
            record.parts[index].sent = true
            try app.savePassedAccess(record) // Intent before wire; failed save remains safely unsent.
            let response = try await api.delegate(invite: guest.invite, fingerprint: app.backupFingerprint(server: record.server),
                operation: .create, body: record.createRequest(part: index))
            try record.acceptCreateReply(response, part: index)
            try saveReply(record)
            try await sync(guest)
        }
    }
    func editObjects(_ id: UUID, sourceID: String, numberIDs: Set<Int>,access: [Int:KeyObjectAccess]? = nil) async -> Bool {
        guard !busy, app.canManageGuestAccess else { return false }
        busy = true; message = nil
        defer { busy = false }
        do {
            try flushSaves()
            guard let guest = app.guests.first(where: { $0.id == sourceID && !$0.paused }) else { throw BackupFailure.noAccess }
            try await sync(guest)
            guard var record = app.passedAccess.first(where: { $0.id == id }), let group = record.group,
                  guest.invite.server == record.server, access == nil || Set(access!.keys) == numberIDs,
                  let snapshot = snapshots[sourceID] else { throw BackupFailure.busy }
            if !record.parts.contains(where:{ $0.sourceID == sourceID }) {
                guard !numberIDs.isEmpty else { return true }
                let settings = try access ?? Dictionary(uniqueKeysWithValues:numberIDs.map { ($0,try KeyObjectAccess(depth:0,pool:1)) })
                try record.addPart(sourceID:sourceID,objects:settings,snapshot:snapshot)
                try app.savePassedAccess(record)
                try await submitUnsent(id)
                return app.passedAccess.first(where:{ $0.id == id })?.parts.first(where:{ $0.sourceID == sourceID }).map { $0.state != .draft } ?? false
            }
            guard let index = record.parts.firstIndex(where: { $0.sourceID == sourceID }),
                  record.parts[index].pendingEdit == nil,
                  ![.revoking, .revoked, .draft].contains(record.parts[index].state) else { throw BackupFailure.busy }
            let part = record.parts[index]
            var desired: [String: KeyObjectAccess] = [:]
            var objects: [[String: Any]] = []
            for number in numberIDs.sorted() {
                guard let allow = snapshot.allowance[number], allow.depth > 0 else { throw BackupFailure.noAccess }
                let old = part.objects[String(number)]
                let requested = try access?[number] ?? old ?? KeyObjectAccess(depth:0,pool:1)
                let settings = try KeyObjectAccess(nativeOnly:allow.nativeOnly,depth:requested.depth,pool:requested.pool)
                try settings.validate()
                guard settings.depth < allow.depth, old != nil || allow.poolLeft > 0,
                      settings == old || settings.pool <= max(1,allow.poolLeft - (old == nil ? 1 : 0)) else { throw BackupFailure.noAccess }
                desired[String(number)] = settings
                objects.append(old == settings && part.childID != nil ? ["id": number] : settings.json(id: number))
            }
            record.parts[index].pendingEdit = desired; record.parts[index].editSent = true
            try app.savePassedAccess(record)
            let operation: DelegationOperation
            let body: Data
            if let child = part.childID {
                operation = .edit
                body = try JSONSerialization.data(withJSONObject: ["child_id": child, "objects": objects], options: .sortedKeys)
            } else if desired.isEmpty {
                guard let code = part.code else { throw BackupFailure.noAccess }
                operation = .cancel
                body = try JSONSerialization.data(withJSONObject: ["code": code], options: .sortedKeys)
            } else {
                operation = .create
                body = try JSONSerialization.data(withJSONObject: ["grp": group, "objects": objects], options: .sortedKeys)
            }
            guard app.canManageGuestAccess else { throw BackupFailure.busy }
            _ = try await api.delegate(invite: guest.invite, fingerprint: app.backupFingerprint(server: record.server), operation: operation, body: body)
            try await sync(guest)
            guard let confirmed = app.passedAccess.first(where:{ $0.id == id })?.parts.first(where:{ $0.sourceID == sourceID }) else { return false }
            return confirmed.pendingEdit == nil
        } catch { message = "Изменение объектов не подтверждено. Сохранённые данные не заменены; обновите передачу перед новым изменением."; return false }
    }
    func revoke(_ id: UUID, retry: Bool = false) async {
        guard !busy, app.canManageGuestAccess else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try flushSaves()
            guard var record = app.passedAccess.first(where: { $0.id == id }), let group = record.group else { throw BackupFailure.noAccess }
            for i in record.parts.indices where record.parts[i].state != .revoked { record.parts[i].state = .revoking }
            try app.savePassedAccess(record)
            for i in record.parts.indices where record.parts[i].state != .revoked {
                guard app.canManageGuestAccess, let guest = app.guests.first(where: { $0.id == record.parts[i].sourceID }) else { throw BackupFailure.noAccess }
                guard !record.parts[i].revokeSent || retry else { continue }
                record.parts[i].revokeSent = true; try app.savePassedAccess(record)
                let body = try JSONSerialization.data(withJSONObject: ["grp": group], options: .sortedKeys)
                let reply = try await api.delegate(invite: guest.invite, fingerprint: app.backupFingerprint(server: record.server), operation: .revoke, body: body)
                guard let row = try JSONSerialization.jsonObject(with: reply) as? [String: Any], (row["ok"] as? NSNumber)?.boolValue == true else { throw BackupFailure.invalidPayload }
                record.parts[i].state = .revoked; try saveReply(record)
            }
        } catch { message = "Отзыв не завершён. Ссылка скрыта, поручительства остановлены; проверьте данные перед повтором отзыва." }
    }
}
