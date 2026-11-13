import Foundation
import Combine
import UIKit
import EntrixyCore

struct OwnerPhoneRequest: Identifiable {
    let server: String
    let callID: String
    let objectID: UUID
    let keyID: UUID
    let press: [String: Any]
    let needsConfirmation: Bool
    var id: String { server + ":" + callID }
}

@MainActor
final class OwnerControlModel: ObservableObject {
    @Published private(set) var connections: [String: GuestConnection] = [:]
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var phoneRequests: [OwnerPhoneRequest] = []
    private unowned let app: AppModel
    private let dialer: @MainActor (URL) async -> Bool
    private var active = false
    private var ownerChanges: AnyCancellable?
    private var workers: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var links: [String: Link] = [:]

    private final class Link {
        let live: OwnerLiveTransport
        var authenticated = false
        var attempt: Attempt?
        var sentBLEDecisions: [String: UInt32] = [:]
        var flushingBLE = false
        init(_ live: OwnerLiveTransport) { self.live = live }
    }
    private final class Attempt {
        let objectID: UUID
        let journalID: UUID
        let actionKey: String
        var command: OwnerCommand
        var callID: String?
        var earlyStatuses: [String: [String: Any]] = [:]
        var timeout: Task<Void, Never>?
        init(objectID: UUID, journalID: UUID, actionKey: String, command: OwnerCommand) {
            self.objectID = objectID; self.journalID = journalID; self.actionKey = actionKey; self.command = command
        }
    }

    init(app: AppModel, dialer: (@MainActor (URL) async -> Bool)? = nil) {
        self.app = app
        self.dialer = dialer ?? { url in
            await withCheckedContinuation { continuation in
                UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
            }
        }
        ownerChanges = app.$owners.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startMissing()
                await self?.flushBLEDecisions()
            }
        }
    }
    func resume() { active = true; startMissing() }
    func suspend() {
        active = false
        workers.values.forEach { $0.cancel() }; workers.removeAll(); generations.removeAll()
        for link in links.values {
            if let attempt = link.attempt { messages[attempt.objectID] = "Результат не получен. Автоматического повтора не будет." }
            link.attempt?.timeout?.cancel(); link.live.close()
        }
        links.removeAll(); phoneRequests.removeAll()
        for server in Array(connections.keys) { connections[server] = .offline }
    }
    private func startMissing() {
        guard active, app.canManageGuestAccess else { return }
        for owner in app.owners where !owner.registrationPending && workers[owner.server] == nil {
            let server = owner.server, generation = UUID()
            generations[server] = generation
            workers[server] = Task { [weak self] in
                var delay: UInt64 = 1
                while !Task.isCancelled {
                    guard let self, self.active, self.generations[server] == generation,
                          let owner = self.app.owners.first(where: { $0.server == server }) else { return }
                    self.connections[server] = .connecting
                    do {
                        let live = try self.app.makeOwnerLive(owner)
                        let link = Link(live); self.links[server] = link
                        for try await frame in live.frames {
                            guard self.active, self.generations[server] == generation, self.links[server] === link else { live.close(); return }
                            try await self.receive(frame, server: server, link: link)
                            if self.connections[server] == .unavailable { break }
                        }
                        live.close(); link.attempt?.timeout?.cancel()
                        if self.links[server] === link { self.links.removeValue(forKey: server) }
                        if self.connections[server] == .unavailable { return }
                    } catch {}
                    guard self.active, !Task.isCancelled, self.generations[server] == generation else { return }
                    self.connections[server] = .offline
                    if let link = self.links.removeValue(forKey: server) { link.attempt?.timeout?.cancel(); link.live.close() }
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    private func flushBLEDecisions() async {
        guard active else { return }
        for (server, link) in links where link.authenticated && !link.flushingBLE {
            link.flushingBLE = true
            do {
                while active, links[server] === link,
                      let record = app.owners.first(where: { $0.server == server })?.bleRevocations?.first(where: { link.sentBLEDecisions[$0.id] != $0.version }) {
                    let frame = try JSONSerialization.data(withJSONObject: record.json, options: .sortedKeys)
                    // Decisions are immutable/idempotent maintenance, not physical
                    // commands. A reconnect republishes their exact versions.
                    link.sentBLEDecisions[record.id] = record.version
                    try await link.live.sendAction(frame)
                }
            } catch { link.live.close() }
            link.flushingBLE = false
        }
    }

    func execute(server: String, objectID: UUID, action: GuestAction) async {
        guard active, app.canManageGuestAccess,
              let owner = app.owners.first(where: { $0.server == server }),
              let object = owner.objects?.first(where: { $0.id == objectID }), let numberID = object.numberID,
              object.pending == nil, object.available != false, let link = links[server], link.authenticated, link.attempt == nil else {
            app.errorMessage = "Нет готового соединения или предыдущий запрос ещё не завершён."
            return
        }
        guard app.ownerManualActionAllowed(object) else { return }
        do {
            guard object.kind == "device" || (object.kind == "webhook" && object.routing["webhook_mode"] == "server") else { throw GuestCrypto.Failure.invalidEnvelope }
            let secret = try object.wrappedSocketSecret.map { try GuestCrypto.decrypt(key: owner.masterKey, envelope: $0) }
            let command = try OwnerCommand(numberID: numberID, kind: object.kind, action: action, secret: secret, now: ProcessInfo.processInfo.systemUptime)
            let frame = try command.request()
            let label = (try object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Объект"
            let actionKey = "owner:" + UUID().uuidString
            let entry = JournalEntry(who: "Я", what: label, actionKey: actionKey, result: "Результат не получен", level: "warning")
            app.recordAction(entry)
            guard app.journal.contains(where: { $0.id == entry.id }) else { return }
            let attempt = Attempt(objectID: objectID, journalID: entry.id, actionKey: actionKey, command: command)
            link.attempt = attempt
            messages[objectID] = "Запрос отправляется"
            attempt.timeout = Task { [weak self, weak link] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, let link, self.links[server] === link else { return }
                self.messages[objectID] = "Результат не получен. Автоматического повтора не будет."
                link.live.close()
            }
            try await link.live.sendAction(frame)
        } catch {
            messages[objectID] = "Не удалось получить результат команды. Автоматического повтора не будет."
            links[server]?.live.close()
            app.errorMessage = object.kind == "device" && object.wrappedSocketSecret == nil
                ? "Контроллеру нужна защищённая настройка перед открытием."
                : "Команда не подтверждена. Повторный запрос автоматически не отправляется."
        }
    }

    private func receive(_ data: Data, server: String, link: Link) async throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = json["type"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
        if type == "host_ok" {
            link.authenticated = true; connections[server] = .connected
            await flushBLEDecisions()
            return
        }
        if type == "evicted" || (type == "error" && ["auth", "wrong_device", "bad_fp"].contains(json["reason"] as? String ?? "")) {
            connections[server] = .unavailable; link.live.close(); return
        }
        guard link.authenticated else { return }
        if ["do_call", "confirm_request"].contains(type) {
            // An invalid guest request does not tear down the owner's command channel.
            try? receivePhoneRequest(json, server: server)
            return
        }
        if ["key_created", "key_updated", "key_mode_changed", "key_revoked", "numbers_update", "key_delegated", "bundle_request"].contains(type) {
            await app.refreshOwners(); return
        }
        guard let attempt = link.attempt, json["silent"] as? Bool != true,
              (json["user_key_id"] as? Int ?? 0) == 0 else { return }
        if let number = json["number_id"] as? Int, number != attempt.command.numberID { return }
        if type == "device_sent" {
            guard json["number_id"] as? Int == attempt.command.numberID,
                  let callID = json["call_id"] as? String, !callID.isEmpty else { return }
            if let expected = attempt.callID, expected != callID { throw GuestCrypto.Failure.invalidEnvelope }
            attempt.callID = callID
            messages[attempt.objectID] = "Запрос передан; ожидаем результат"
            if let early = attempt.earlyStatuses.removeValue(forKey: callID) {
                try await receive(JSONSerialization.data(withJSONObject: early), server: server, link: link)
            }
            attempt.earlyStatuses.removeAll()
        } else if type == "sock_challenge" {
            guard let commandID = json["command_id"] as? String,
                  attempt.callID == nil || attempt.callID == commandID else { return }
            let proof = try attempt.command.fire(challenge: json, now: ProcessInfo.processInfo.systemUptime)
            attempt.callID = commandID
            try await link.live.sendAction(proof)
        } else if type == "device_status" {
            guard let callID = json["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 256,
                  let message = json["message"] as? String, !message.isEmpty, message.utf8.count <= 4096 else { return }
            if attempt.callID == nil {
                if attempt.earlyStatuses.count < 4 { attempt.earlyStatuses[callID] = json }
                return
            }
            guard callID == attempt.callID else { return }
            let level = json["level"] as? String ?? "info"
            messages[attempt.objectID] = message
            // Only an actual controller/server response changes the durable result.
            if app.journal.contains(where: { $0.id == attempt.journalID }) { app.actionResult(actionKey: attempt.actionKey, result: message, level: level, replace: true) }
            if json["final"] as? Bool != false { attempt.timeout?.cancel(); link.attempt = nil; link.live.close() }
        } else if type == "error", let reason = json["reason"] as? String,
                  ["device_offline", "forbidden", "not_device", "not_webhook", "rate_limit", "rate_limited"].contains(reason) {
            let message = reason == "device_offline" ? "Контроллер не в сети" : "Сервер отклонил запрос"
            messages[attempt.objectID] = message
            let correlated = json["number_id"] as? Int == attempt.command.numberID
                || (attempt.callID != nil && json["call_id"] as? String == attempt.callID)
            if correlated && app.journal.contains(where: { $0.id == attempt.journalID }) {
                app.actionResult(actionKey: attempt.actionKey, result: message, level: "danger", replace: true)
            } else { messages[attempt.objectID] = "Сервер вернул ошибку; результат команды не подтверждён" }
            attempt.timeout?.cancel(); link.attempt = nil; link.live.close()
        }
    }

    private func receivePhoneRequest(_ json: [String: Any], server: String) throws {
        guard app.canManageGuestAccess, phoneRequests.count < 4, app.ownerMessages[server] == nil,
              let owner = app.owners.first(where: { $0.server == server }),
              let synced = owner.lastSynced, Date().timeIntervalSince(synced) < 120,
              let number = json["number_id"] as? Int,
              let object = owner.objects?.first(where: { $0.numberID == number && $0.kind == "call" && $0.pending == nil && $0.available != false }),
              let keyID = json["user_key_id"] as? Int,
              let key = try owner.authorizedGuest(keyID: keyID, numberID: number),
              let press = json["press"] as? [String: Any],
              let callID = json["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 256 else { return }
        let nonce = try OwnerGuestPress.verify(press, publicKey: key.publicKey, server: server, numberID: number)
        try app.consumeOwnerPress(server + ":" + key.id.uuidString + ":" + nonce)
        phoneRequests.append(OwnerPhoneRequest(server: server, callID: callID, objectID: object.id, keyID: key.id, press: press, needsConfirmation: json["type"] as? String == "confirm_request"))
    }

    func decline(_ request: OwnerPhoneRequest) async {
        phoneRequests.removeAll { $0.id == request.id }
        guard let link = links[request.server], link.authenticated else { return }
        let body: [String: Any] = request.needsConfirmation
            ? ["type": "confirm_response", "call_id": request.callID, "accept": false]
            : ["type": "call_status", "call_id": request.callID, "status": "error"]
        if let data = try? JSONSerialization.data(withJSONObject: body) { try? await link.live.sendAction(data) }
    }

    func dial(server: String, objectID: UUID, request: OwnerPhoneRequest? = nil) async {
        guard active, app.canManageGuestAccess,
              let owner = app.owners.first(where: { $0.server == server }),
              let object = owner.objects?.first(where: { $0.id == objectID && $0.kind == "call" && $0.pending == nil && $0.available != false }),
              let phone = object.localPhone, !phone.isEmpty,
              phone.enumerated().allSatisfy({ $0.element.isASCII && ($0.element.isNumber || ($0.offset == 0 && $0.element == "+")) }),
              let url = URL(string: "tel:" + phone) else { app.errorMessage = "Не удалось прочитать локальный номер владельца."; return }
        if request == nil, !app.ownerManualActionAllowed(object) { return }
        var who = "Я"
        if let request {
            guard phoneRequests.contains(where: { $0.id == request.id }),
                  let number = object.numberID,
                  let key = try? owner.authorizedGuest(localID: request.keyID, numberID: number) else { return }
            do { _ = try OwnerGuestPress.verify(request.press, publicKey: key.publicKey, server: server, numberID: number) }
            catch { await decline(request); app.errorMessage = "Запрос гостя устарел или больше не разрешён."; return }
            who = key.label
            phoneRequests.removeAll { $0.id == request.id }
            if request.needsConfirmation {
                guard let link = links[server], link.authenticated else { return }
                do { try await link.live.sendAction(JSONSerialization.data(withJSONObject: ["type": "confirm_response", "call_id": request.callID, "accept": true])) }
                catch { app.errorMessage = "Не удалось подтвердить запрос гостя."; return }
            }
        }
        let label = (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Объект"
        let actionKey = "owner-phone:" + UUID().uuidString
        let entry = JournalEntry(who: who, what: label, actionKey: actionKey, result: "Результат звонка не подтверждён", level: "warning")
        app.recordAction(entry)
        guard app.journal.contains(where: { $0.id == entry.id }) else { return }
        let accepted = await dialer(url)
        app.actionResult(actionKey: actionKey, result: accepted ? "Передано приложению «Телефон»" : "Приложение «Телефон» не открылось", level: accepted ? "info" : "danger", replace: true)
        if let request, let link = links[server], link.authenticated {
            let status = accepted ? "phone_handoff" : "error"
            if let frame = try? JSONSerialization.data(withJSONObject: ["type": "call_status", "call_id": request.callID, "status": status]) {
                try? await link.live.sendAction(frame)
            }
        }
    }
}
