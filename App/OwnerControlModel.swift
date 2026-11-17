import Foundation
import Combine
import UIKit
import CallKit
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
    @Published private(set) var phoneRequests: [OwnerPhoneRequest] = [] {
        didSet { app.ownerGuestRequestPending = !phoneRequests.isEmpty }
    }
    private unowned let app: AppModel
    private let dialer: @MainActor (URL) async -> Bool
    private let webhook: any PhoneWebhookSending
    private let notices: any OwnerPhoneNoticePosting
    private let phoneBusy: @MainActor () -> Bool
    private var automaticPhoneRequests = Set<String>()
    private var notifyPhoneTasks: [String: Task<Void, Never>] = [:]
    private var notifyPhoneRequests: [String: OwnerPhoneRequest] = [:]
    private var webhookInFlight = Set<ObjectReference>()
    private var webhookTasks: [ObjectReference: Task<PhoneWebhookReply, Error>] = [:]
    private var webhookPositionTasks: [ObjectReference: Task<Void, Never>] = [:]
    private var webhookPositionGeneration: [ObjectReference: UUID] = [:]
    private var acceptedWebhookRequests = Set<String>()
    private var active = false
    private var ownerChanges: AnyCancellable?
    private var workers: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var links: [String: Link] = [:]

    @Published private(set) var positions: [String: [Int: String]] = [:]
    @Published private(set) var onlineDevices: [String: Set<Int>] = [:]
    func cardStatus(server: String, object: OwnerObject) -> String {
        if object.kind == "ble" { return "Bluetooth" }
        if object.kind == "call" { return "Звонок с подтверждением iPhone" }
        if object.kind == "device" {
            guard object.wrappedSocketSecret != nil else { return "Нужна защищённая настройка контроллера" }
            guard connections[server] == .connected else { return (connections[server] ?? .offline).title }
            let id = object.routing["device_id_ref"].flatMap(Int.init)
            return id.map { onlineDevices[server]?.contains($0) == true } == true ? "Контроллер в сети" : "Контроллер не в сети"
        }
        return (connections[server] ?? .offline).title
    }
    func readyForTap(server: String) -> Bool {
        active && links[server]?.authenticated == true && links[server]?.attempt == nil
    }
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

    init(app: AppModel, dialer: (@MainActor (URL) async -> Bool)? = nil, webhook: any PhoneWebhookSending = PhoneWebhookTransport(), notices: (any OwnerPhoneNoticePosting)? = nil,
         phoneBusy: (@MainActor () -> Bool)? = nil) {
        self.app = app; self.webhook = webhook
        self.notices = notices ?? OwnerPhoneNotifications()
        self.phoneBusy = phoneBusy ?? { CXCallObserver().calls.contains { !$0.hasEnded } }
        self.dialer = dialer ?? { url in
            await withCheckedContinuation { continuation in
                UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
            }
        }
        self.notices.cancelled = { [weak self] id in
            guard let self else { return }
            self.notifyPhoneTasks.removeValue(forKey: id)?.cancel()
            self.automaticPhoneRequests.remove(id)
            self.notices.remove(id: id)
            if let request = self.notifyPhoneRequests.removeValue(forKey: id) { Task { await self.callStatus(request, status: "declined") } }
        }
        ownerChanges = app.$owners.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startMissing()
                self?.prunePhoneRequests()
                await self?.flushBLEDecisions()
            }
        }
    }
    func resume() { active = true; startMissing() }
    func suspend() {
        active = false
        webhookTasks.values.forEach { $0.cancel() }
        webhookPositionTasks.values.forEach { $0.cancel() }; webhookPositionTasks.removeAll(); webhookPositionGeneration.removeAll()
        acceptedWebhookRequests.removeAll()
        for (id, task) in notifyPhoneTasks { task.cancel(); notices.remove(id: id) }
        notifyPhoneTasks.removeAll(); notifyPhoneRequests.removeAll(); automaticPhoneRequests.removeAll()
        workers.values.forEach { $0.cancel() }; workers.removeAll(); generations.removeAll()
        for link in links.values {
            if let attempt = link.attempt { messages[attempt.objectID] = "Результат не получен. Автоматического повтора не будет." }
            link.attempt?.timeout?.cancel(); link.live.close()
        }
        links.removeAll(); phoneRequests.removeAll(); positions.removeAll(); onlineDevices.removeAll()
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
                    self.positions.removeValue(forKey: server)
                    self.onlineDevices.removeValue(forKey: server)
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
            messages[objectID] = "Нет готового соединения или предыдущий запрос ещё не завершён."
            return
        }
        guard app.ownerManualActionAllowed(object, server: server, action: action) else { return }
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
            messages[objectID] = object.kind == "device" && object.wrappedSocketSecret == nil
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
        if type == "avatar_request", let number = json["number_id"] as? Int, number > 0,
           let guestOID = json["guest_oid"] as? Int, guestOID > 0,
           let owner = app.owners.first(where: { $0.server == server }),
           let object = owner.objects?.first(where: { $0.numberID == number && $0.pending != .delete }) {
            var reply: [String: Any] = ["type": "avatar_data", "number_id": number, "guest_oid": guestOID]
            if try object.metadata(masterKey: owner.masterKey)["avatar_type"] as? String == "file", let cipher = object.avatarCipher {
                reply["avatar_cipher"] = cipher
            } else { reply["data"] = "" }
            try await link.live.sendAction(JSONSerialization.data(withJSONObject: reply, options: .sortedKeys))
            return
        }
        if type == "confirm_expired", let callID = json["call_id"] as? String {
            phoneRequests.removeAll { $0.server == server && $0.callID == callID }; return
        }
        if type == "do_webhook" {
            if let request = try? verifiedPhoneRequest(json, server: server, webhookOnly: true) {
                acceptedWebhookRequests.insert(request.id)
                Task { [weak self] in await self?.phoneWebhook(server: server, objectID: request.objectID, request: request) }
            }
            return
        }
        if ["do_call", "confirm_request"].contains(type) {
            // An invalid guest request does not tear down the owner's command channel.
            try? receivePhoneRequest(json, server: server)
            return
        }
        if ["key_created", "key_updated", "key_mode_changed", "key_revoked", "numbers_update", "key_delegated", "bundle_request"].contains(type) {
            await app.refreshOwners(); return
        }
        if type == "obj_state_update", let number = json["num_id"] as? Int,
           let position = json["position"] as? String, ["open", "closed", "opening", "closing", "unknown"].contains(position) {
            if let id = app.owners.first(where: { $0.server == server })?.objects?.first(where: { $0.numberID == number })?.id {
                let target = ObjectReference.owned(server: server, objectID: id)
                webhookPositionGeneration[target] = UUID(); webhookPositionTasks.removeValue(forKey: target)?.cancel()
            }
            positions[server, default: [:]][number] = position
            return
        }
        if type == "devices_online", let ids = json["device_ids"] as? [Int] {
            onlineDevices[server] = Set(ids); return
        }
        if type == "device_online", let id = json["device_id"] as? Int, let online = json["online"] as? Bool {
            if online { onlineDevices[server, default: []].insert(id) }
            else { onlineDevices[server, default: []].remove(id) }
            return
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

    private func verifiedPhoneRequest(_ json: [String: Any], server: String, webhookOnly: Bool = false) throws -> OwnerPhoneRequest? {
        guard app.canManageGuestAccess, app.ownerMessages[server] == nil,
              let owner = app.owners.first(where: { $0.server == server }),
              let synced = owner.lastSynced, Date().timeIntervalSince(synced) < 120,
              let number = json["number_id"] as? Int,
              let object = owner.objects?.first(where: { $0.numberID == number && $0.pending == nil && $0.available != false }),
              webhookOnly ? (object.kind == "webhook" && object.routing["webhook_mode"] == "phone") :
                (object.kind == "call" || (json["type"] as? String == "confirm_request" && object.kind == "webhook" && object.routing["webhook_mode"] == "phone")),
              let keyID = json["user_key_id"] as? Int,
              let key = try owner.authorizedGuest(keyID: keyID, numberID: number),
              let press = json["press"] as? [String: Any],
              let callID = json["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 256 else { return nil }
        let expectedAction = webhookOnly ? (json["action"] as? String ?? "") : ""
        guard press["action"] as? String == expectedAction else { return nil }
        let nonce = try OwnerGuestPress.verify(press, publicKey: key.publicKey, server: server, numberID: number)
        try app.consumeOwnerPress(server + ":" + key.id.uuidString + ":" + nonce)
        return OwnerPhoneRequest(server: server, callID: callID, objectID: object.id, keyID: key.id,
            press: press, needsConfirmation: json["type"] as? String == "confirm_request")
    }
    private func prunePhoneRequests() {
        phoneRequests = phoneRequests.filter { request in
            guard let owner = app.owners.first(where: { $0.server == request.server }),
                  let object = owner.objects?.first(where: { $0.id == request.objectID && $0.pending == nil && $0.available != false }),
                  let number = object.numberID,
                  (try? owner.authorizedGuest(localID: request.keyID, numberID: number)) != nil else { return false }
            return object.kind == "call" || (object.kind == "webhook" && object.routing["webhook_mode"] == "phone")
        }
    }
    private func receivePhoneRequest(_ json: [String: Any], server: String) throws {
        guard phoneRequests.count + automaticPhoneRequests.count < 4,
              let request = try verifiedPhoneRequest(json, server: server),
              let owner = app.owners.first(where: { $0.server == server }),
              let object = owner.objects?.first(where: { $0.id == request.objectID }), let number = object.numberID else { return }
        let preference = owner.callPreference(guestID: request.keyID, numberID: number)
        if object.kind == "call", preference?.reaction == "off" {
            Task { await decline(request) }; return
        }
        // A migrated key with no explicit local choice retains the earlier
        // iOS explicit-tap behavior. New form choices follow Android's reaction.
        if object.kind != "call" || request.needsConfirmation || preference == nil || preference?.reaction == "confirm" {
            phoneRequests.append(request); return
        }
        if object.kind == "call", phoneBusy(), preference?.serveDuringCall != true {
            Task { await callStatus(request, status: "busy") }; return
        }
        automaticPhoneRequests.insert(request.id)
        if preference?.reaction == "notify" {
            notifyPhoneRequests[request.id] = request
            let label = (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? ""
            let guest = (try? owner.authorizedGuest(localID: request.keyID, numberID: number))?.label ?? ""
            notifyPhoneTasks[request.id] = Task { [weak self] in
                guard let self else { return }
                guard await self.notices.show(id: request.id, guest: guest, object: label), self.active,
                      self.automaticPhoneRequests.contains(request.id) else {
                    self.automaticPhoneRequests.remove(request.id); self.notifyPhoneTasks.removeValue(forKey: request.id); self.notifyPhoneRequests.removeValue(forKey: request.id)
                    await self.callStatus(request, status: "error"); return
                }
                await self.callStatus(request, status: "scheduled")
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard !Task.isCancelled, self.active, self.automaticPhoneRequests.contains(request.id) else { return }
                self.notices.remove(id: request.id)
                await self.dial(server: server, objectID: request.objectID, request: request)
                self.notifyPhoneTasks.removeValue(forKey: request.id); self.notifyPhoneRequests.removeValue(forKey: request.id)
            }
        } else { Task { [weak self] in await self?.dial(server: server, objectID: request.objectID, request: request) } }
    }
    private func callStatus(_ request: OwnerPhoneRequest, status: String) async {
        guard active, let link = links[request.server], link.authenticated,
              let data = try? JSONSerialization.data(withJSONObject: ["type": "call_status", "call_id": request.callID, "status": status]) else { return }
        try? await link.live.sendAction(data)
    }
    func approve(_ request: OwnerPhoneRequest) async {
        guard let object = app.owners.first(where: { $0.server == request.server })?.objects?.first(where: { $0.id == request.objectID }) else { return }
        if object.kind == "webhook" { await phoneWebhook(server: request.server, objectID: request.objectID, request: request) }
        else { await dial(server: request.server, objectID: request.objectID, request: request) }
    }

    func decline(_ request: OwnerPhoneRequest) async {
        phoneRequests.removeAll { $0.id == request.id }
        automaticPhoneRequests.remove(request.id); notifyPhoneTasks.removeValue(forKey: request.id)?.cancel(); notifyPhoneRequests.removeValue(forKey: request.id); notices.remove(id: request.id)
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
        if request == nil, !app.ownerManualActionAllowed(object, server: server, action: .open) { return }
        var who = "Я"
        if let request {
            let explicit = phoneRequests.contains(where: { $0.id == request.id })
            let automatic = automaticPhoneRequests.remove(request.id) != nil
            guard explicit || automatic, let number = object.numberID,
                  let key = try? owner.authorizedGuest(localID: request.keyID, numberID: number) else { return }
            let preference = owner.callPreference(guestID: request.keyID, numberID: number)
            guard preference?.reaction != "off", (!phoneBusy() || preference?.serveDuringCall == true),
                  !automatic || ["auto", "notify"].contains(preference?.reaction ?? "") else { return }
            do { _ = try OwnerGuestPress.verify(request.press, publicKey: key.publicKey, server: server, numberID: number) }
            catch { await decline(request); app.errorMessage = "Запрос гостя устарел или больше не разрешён."; return }
            who = ProductText.string("journal_who_guest", key.label)
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
    func phoneWebhookReady(server: String, objectID: UUID) -> Bool {
        active && !webhookInFlight.contains(.owned(server: server, objectID: objectID))
    }
    func phoneWebhook(server: String, objectID: UUID, action requested: GuestAction = .open, request: OwnerPhoneRequest? = nil) async {
        defer { if let request { acceptedWebhookRequests.remove(request.id) } }
        let target = ObjectReference.owned(server: server, objectID: objectID)
        guard active, app.canManageGuestAccess, !webhookInFlight.contains(target),
              let owner = app.owners.first(where: { $0.server == server }),
              let object = owner.objects?.first(where: { $0.id == objectID && $0.kind == "webhook" && $0.pending == nil && $0.available != false }),
              object.routing["webhook_mode"] == "phone", let number = object.numberID,
              let url = object.routing["webhook_url"], let secret = object.routing["webhook_secret"] else { return }
        if request == nil, !app.ownerManualActionAllowed(object, server: server, action: requested) { return }
        var who = "Я", direction: GuestAction? = requested
        if let request {
            guard request.server == server, request.objectID == objectID,
                  let key = try? owner.authorizedGuest(localID: request.keyID, numberID: number) else { return }
            do { _ = try OwnerGuestPress.verify(request.press, publicKey: key.publicKey, server: server, numberID: number) }
            catch { await decline(request); return }
            if request.needsConfirmation {
                guard phoneRequests.contains(where: { $0.id == request.id }), let link = links[server], link.authenticated else { return }
                phoneRequests.removeAll { $0.id == request.id }
                do { try await link.live.sendAction(JSONSerialization.data(withJSONObject: ["type": "confirm_response", "call_id": request.callID, "accept": true])) }
                catch { return }
            } else { guard acceptedWebhookRequests.remove(request.id) != nil else { return } }
            who = ProductText.string("journal_who_guest", key.label)
            let signed = request.press["action"] as? String ?? ""
            direction = signed.isEmpty ? nil : GuestAction(rawValue: signed)
        }
        let metadata = try? object.metadata(masterKey: owner.masterKey)
        let toggles = metadata?["wh_toggle"] as? Int == 1
        let action = PhoneWebhook.action(requested: direction, toggles: toggles, position: positions[server]?[number])
        guard let body = try? PhoneWebhook.request(numberID: number, action: action, secret: secret),
              active, app.canManageGuestAccess, !webhookInFlight.contains(target),
              app.owners.first(where: { $0.server == server })?.objects?.first(where: { $0.id == objectID }) == object else { return }
        webhookInFlight.insert(target)
        defer { webhookInFlight.remove(target); webhookTasks.removeValue(forKey: target) }
        let actionKey = "owner-webhook:" + UUID().uuidString
        let entry = JournalEntry(who: who, what: metadata?["label"] as? String ?? "Объект", actionKey: actionKey,
            result: "Результат запроса не получен", level: "warning")
        app.recordAction(entry)
        guard app.journal.contains(where: { $0.id == entry.id }) else { return }
        let task = Task { try await webhook.send(url: url, body: body) }
        webhookTasks[target] = task
        do {
            let result = try await task.value
            let message = result.message ?? ProductText.string(result.level == "success" ? "ble_st_opened" : "webhook_failed")
            messages[objectID] = message
            app.actionResult(actionKey: actionKey, result: message, level: result.level, replace: true)
            let position = result.positionAfter(action: action, toggles: toggles)
            if let position, active {
                let generation = UUID(); webhookPositionGeneration[target] = generation
                webhookPositionTasks[target]?.cancel()
                await setWebhookPosition(server: server, number: number, objectID: objectID, position: position, push: request == nil)
                let forget = result.forgetting(position: position)
                if webhookPositionGeneration[target] == generation { webhookPositionTasks[target] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(forget.after * 1_000_000_000)) } catch { return }
                    guard let self, self.active, self.webhookPositionGeneration[target] == generation else { return }
                    await self.setWebhookPosition(server: server, number: number, objectID: objectID, position: forget.position, push: true)
                    if self.webhookPositionGeneration[target] == generation { self.webhookPositionTasks.removeValue(forKey: target) }
                } }
            }
            if let request { await sendWebhookReply(request, level: result.level, message: message, position: position) }
        } catch {
            let message = ProductText.string("webhook_failed")
            messages[objectID] = message
            app.actionResult(actionKey: actionKey, result: message, level: "danger", replace: true)
            if let request { await sendWebhookReply(request, level: "danger", message: message, position: nil) }
        }
    }
    private func setWebhookPosition(server: String, number: Int, objectID: UUID, position: String, push: Bool) async {
        guard active, app.owners.first(where: { $0.server == server })?.objects?.contains(where: { $0.id == objectID && $0.numberID == number && $0.pending != .delete }) == true else { return }
        positions[server, default: [:]][number] = position
        if push, let link = links[server], link.authenticated,
           let data = try? JSONSerialization.data(withJSONObject: ["type": "obj_state_push", "num_id": number, "position": position]) {
            try? await link.live.sendAction(data)
        }
    }
    private func sendWebhookReply(_ request: OwnerPhoneRequest, level: String, message: String, position: String?) async {
        guard active, let link = links[request.server], link.authenticated else { return }
        var frame: [String: Any] = ["type": "webhook_result", "call_id": request.callID, "level": level, "message": message]
        if let position { frame["position"] = position }
        if let data = try? JSONSerialization.data(withJSONObject: frame) { try? await link.live.sendAction(data) }
    }

}
