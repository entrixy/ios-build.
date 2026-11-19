import Foundation
import UIKit
import EntrixyCore

struct NativePushInbox: Codable {
    var events: [NativePushEvent] = []
    func validate() throws {
        guard events.count <= 64, Set(events.map(\.identity)).count == events.count else { throw GuestCrypto.Failure.invalidEnvelope }
        try events.forEach { try $0.validate() }
    }
}
protocol NativePushInboxStorage {
    func load() throws -> NativePushInbox
    func save(_ inbox: NativePushInbox) throws
}
struct FileNativePushInboxStorage: NativePushInboxStorage {
    private func file() throws -> URL {
        var folder = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("NativePush",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        return folder.appendingPathComponent("inbox.json")
    }
    func load() throws -> NativePushInbox {
        let url = try file()
        guard FileManager.default.fileExists(atPath:url.path) else { return NativePushInbox() }
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        let data = try handle.read(upToCount:65537) ?? Data()
        guard data.count <= 65536 else { throw GuestCrypto.Failure.invalidEnvelope }
        let value = try JSONDecoder().decode(NativePushInbox.self,from:data); try value.validate(); return value
    }
    func save(_ inbox: NativePushInbox) throws {
        try inbox.validate()
        let data = try JSONEncoder().encode(inbox)
        guard data.count <= 65536 else { throw GuestCrypto.Failure.invalidEnvelope }
        try data.write(to:file(),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// APNs carries only an invalidation hint. Foreground authenticated APIs provide
/// current ciphertext; existing message verification/persistence/ACK owns delivery.
/// No opening, authentication bypass, persistent socket or background timer.
@MainActor final class AppRemoteNotifications {
    private unowned let app: AppModel
    private let storage: NativePushInboxStorage
    private let api: NativePushTransport
    private let register: () -> Void
    private let unregister: () -> Void
    private let environment: NativePushRegistration.Environment?
    private var inbox: NativePushInbox?
    private var registration: NativePushRegistration?
    private var successful: [String:Date] = [:]
    private var retryAfter: [String:Date] = [:]
    private var active = false
    private var worker: Task<Void,Never>?
    private var generation = UUID()
    private var wakeGeneration = UUID()
    private var lastSweep = Date.distantPast
    private var pendingSweep = Set<String>()
    private var askedRegistration = false
    private var osRetryAfter = Date.distantPast
    init(app:AppModel,storage:NativePushInboxStorage = FileNativePushInboxStorage(),api:NativePushTransport = GuestAPI(),
         environment:NativePushRegistration.Environment? = NativePushRegistration.Environment(rawValue:Bundle.main.object(forInfoDictionaryKey:"EntrixyPushEnvironment") as? String ?? ""),
         register:(() -> Void)? = nil,unregister:(() -> Void)? = nil) {
        self.app = app; self.storage = storage; self.api = api; self.environment = environment
        self.register = register ?? { UIApplication.shared.registerForRemoteNotifications() }
        self.unregister = unregister ?? { UIApplication.shared.unregisterForRemoteNotifications() }
    }
    func activate() {
        active = true
        guard app.canManageGuestAccess else { return }
        if environment != nil && Date() >= osRetryAfter && app.guests.contains(where:{$0.invite.server == "entrixy.com"}) { askedRegistration = true; register() }
        schedule()
    }
    func pause() { active = false; generation = UUID(); worker?.cancel(); worker = nil }
    func removed(_ invite:GuestInvite) {
        let previousRegistration = registration
        successful.removeValue(forKey:invite.id)
        pendingSweep.remove(invite.id)
        if inbox != nil,var value = try? load() {
            value.events.removeAll { $0.server == invite.server && $0.keyHash == GuestCrypto.hash(Data(invite.userKey.utf8)) }
            if (try? storage.save(value)) != nil { inbox = value }
        }
        guard invite.server == "entrixy.com" else { return }
        if !app.guests.contains(where:{$0.invite.server == "entrixy.com"}) {
            unregister(); askedRegistration = false; registration = nil; successful.removeAll()
        }
        guard let registration = previousRegistration else { return }
        guard let fingerprint = try? app.backupFingerprint(server:invite.server) else { return }
        let api = self.api, pending = worker
        Task { [weak self,weak model = app] in
            // The durable local deletion comes first; do not race an in-flight
            // registration or retain removed credentials in a persistent queue.
            await pending?.value
            guard let model,!model.guests.contains(where:{$0.id == invite.id}) else { return }
            try? await api.removeNativePush(registration,invite:invite,fingerprint:fingerprint)
            if model.guests.contains(where:{$0.id == invite.id}),let self { successful.removeValue(forKey:invite.id); schedule() }
        }
    }
    func registrationFailed() { askedRegistration = false; osRetryAfter = Date().addingTimeInterval(60) }
    func receivedDeviceToken(_ token:Data) {
        guard let environment, let next = try? NativePushRegistration(token:token.map { String(format:"%02x",$0) }.joined(),environment:environment) else { return }
        askedRegistration = true
        if registration != next { registration = next; successful.removeAll(); retryAfter.removeAll(); wakeGeneration = UUID() }
        schedule()
    }
    @discardableResult func receive(_ payload:[AnyHashable:Any]) -> Bool {
        guard app.storageReady,let event = try? NativePushEvent(payload:Dictionary(uniqueKeysWithValues:payload.compactMap { key,value in (key as? String).map { ($0,value) } })),
              event.server == "entrixy.com",
              app.guests.contains(where:{ $0.invite.server == event.server && GuestCrypto.hash(Data($0.invite.userKey.utf8)) == event.keyHash }) else { return false }
        do {
            var value = try load()
            value.events.removeAll { Date().timeIntervalSince($0.receivedAt) > 7*86400 }
            if let index = value.events.firstIndex(where:{ $0.identity == event.identity }) {
                value.events[index] = event
            } else {
                guard value.events.count < 64 else { return false }
                value.events.append(event)
            }
            try storage.save(value); inbox = value; wakeGeneration = UUID()
            retryAfter.removeValue(forKey:"message:"+event.server+":"+event.keyHash)
            schedule(); return true
        } catch { return false } // Preserve an unreadable queue; never replace identity/state.
    }
    private func load() throws -> NativePushInbox {
        if let inbox { return inbox }
        let value = try storage.load(); try value.validate(); inbox = value; return value
    }
    func schedule() {
        guard active,app.canManageGuestAccess,worker == nil,environment != nil else { return }
        if registration == nil && !askedRegistration && Date() >= osRetryAfter && app.guests.contains(where:{$0.invite.server == "entrixy.com"}) {
            askedRegistration = true; register()
        }
        guard !app.guests.isEmpty,(inbox == nil || Date().timeIntervalSince(lastSweep) >= 60 || !eligible(now:Date()).isEmpty) else { return }
        let ticket = generation
        let wake = wakeGeneration
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == ticket { worker = nil; if wakeGeneration != wake || (inbox != nil && !eligible(now:Date()).isEmpty) { schedule() } }
            }
            await synchronize(ticket)
        }
    }
    private func eligible(now:Date) -> [SavedGuest] {
        let hints = Set((inbox?.events ?? []).map { $0.server+":"+$0.keyHash })
        let rows = app.guests.filter { guest in
            let id = guest.id
            let registrationDue = registration != nil && guest.invite.server == "entrixy.com"
                && now.timeIntervalSince(successful[id] ?? .distantPast) >= 7*86400 && now >= (retryAfter["register:"+id] ?? .distantPast)
            let messageDue = (hints.contains(id) || pendingSweep.contains(id)) && now >= (retryAfter["message:"+id] ?? .distantPast)
            return registrationDue || messageDue
        }
        return rows.filter { hints.contains($0.id) } + rows.filter { !hints.contains($0.id) }
    }
    private func synchronize(_ ticket:UUID) async {
        guard let queued = try? load(), !app.guests.isEmpty else { return }
        let now = Date(), sweep = now.timeIntervalSince(lastSweep) >= 60
        if sweep { lastSweep = now; pendingSweep = Set(app.guests.map(\.id)) }
        let selected = Array(eligible(now:now).prefix(8))
        for guest in selected {
            guard !Task.isCancelled,active,generation == ticket,app.canManageGuestAccess,app.guests.contains(where:{$0.id == guest.id && $0.invite == guest.invite}) else { return }
            let identity = guest.id
            let registerID = "register:"+identity, messageID = "message:"+identity
            guard let fingerprint = try? app.backupFingerprint(server:guest.invite.server) else {
                retryAfter[registerID] = Date().addingTimeInterval(60)
                retryAfter[messageID] = Date().addingTimeInterval(60)
                return
            }
            // APNs identifies this app installation across servers. Never give
            // that token to an arbitrary self-hosted access server automatically.
            if guest.invite.server == "entrixy.com",let registration,now.timeIntervalSince(successful[identity] ?? .distantPast) >= 7*86400,now >= (retryAfter[registerID] ?? .distantPast) {
                do {
                    try await api.registerNativePush(registration,invite:guest.invite,fingerprint:fingerprint)
                    guard !Task.isCancelled,active,generation == ticket else { return }
                    if self.registration == registration,app.guests.contains(where:{$0.id == guest.id && $0.invite == guest.invite}) { successful[identity] = Date() }
                } catch {
                    guard !Task.isCancelled,generation == ticket else { return }
                    retryAfter[registerID] = retryDate(error)
                }
            }
            guard !Task.isCancelled,active,generation == ticket,app.canManageGuestAccess,
                  app.guests.contains(where:{$0.id == guest.id && $0.invite == guest.invite}) else { return }
            let hash = GuestCrypto.hash(Data(guest.invite.userKey.utf8))
            let hints = queued.events.filter { $0.server == guest.invite.server && $0.keyHash == hash }
            if !hints.isEmpty || pendingSweep.contains(identity) {
                guard now >= (retryAfter[messageID] ?? .distantPast) else { continue }
                pendingSweep.remove(identity)
                retryAfter[messageID] = Date().addingTimeInterval(60)
                do {
                    if let cipher = try await api.pendingNativeMessage(invite:guest.invite,fingerprint:fingerprint) {
                        guard !Task.isCancelled,active,generation == ticket,app.canManageGuestAccess,
                              app.guests.contains(where:{$0.id == guest.id && $0.invite == guest.invite}) else { return }
                        let delegated = app.receivedDelegations.contains { $0.parts.contains { $0.guestID == guest.id } }
                        // Android ignores direct-owner messages on delegated keys.
                        guard delegated == cipher.contains("|") else { continue }
                        await app.messages.receive(cipher,guestID:guest.id)
                        guard app.incomingMessages.contains(where:{$0.guestID == guest.id && $0.cipher == cipher}) else { continue }
                    }
                    guard !Task.isCancelled,active,generation == ticket,app.canManageGuestAccess else { return }
                    if hints.contains(where:{$0.kind == .additionalPart}) { await app.delegationInbox.refreshAdditionalParts() }
                    var current = try load()
                    // Remove only the hints observed by this operation. A newer event survives.
                    current.events.removeAll { hints.contains($0) }
                    try storage.save(current); inbox = current
                } catch {
                    guard !Task.isCancelled,generation == ticket else { return }
                    retryAfter[messageID] = retryDate(error)
                }
            }
        }
    }
    private func retryDate(_ error:Error) -> Date {
        let unavailable = (error as? GuestAPI.Failure).map { [404,405,501,503].contains($0.status) } ?? false
        return Date().addingTimeInterval(unavailable ? 86400 : 60)
    }
}
