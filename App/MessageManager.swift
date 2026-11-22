import Foundation
import Combine
import EntrixyCore

@MainActor
final class MessageManager: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private unowned let app: AppModel
    private let acknowledgements: GuestMessageTransport
    private let delegation: DelegationTransport
    init(app: AppModel, acknowledgements: GuestMessageTransport = GuestAPI(), delegation: DelegationTransport = GuestAPI()) {
        self.app = app; self.acknowledgements = acknowledgements; self.delegation = delegation
    }
    func text(_ saved: SavedMessage) throws -> String {
        guard let guest = app.guests.first(where: { $0.id == saved.guestID }) else { throw BackupFailure.noAccess }
        if let group = saved.delegationWelcomeGroup {
            guard let receipt = app.receivedDelegations.first(where: { $0.id == group && $0.guestIDs.contains(guest.id) }) else { throw BackupFailure.noAccess }
            return try DelegationWelcome.open(saved.cipher, secret: receipt.link.secret).text
        }
        let pair = app.receivedDelegations.first { $0.guestIDs.contains(guest.id) }?.recipient ?? guest.incomingRecipient
        return try GuestMessageCrypto.open(saved.cipher, bundleKey: guest.invite.bundleKey, recipient: pair)
    }
    func sender(_ saved: SavedMessage) -> String? {
        guard let guest = app.guests.first(where: { $0.id == saved.guestID }), (try? text(saved)) != nil else { return nil }
        if let group = saved.delegationWelcomeGroup {
            guard let receipt = app.receivedDelegations.first(where: { $0.id == group }),
                  let value = try? DelegationWelcome.open(saved.cipher, secret: receipt.link.secret),
                  !value.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value.from
        }
        let receipt = app.receivedDelegations.first { $0.guestIDs.contains(guest.id) }
        let from: String?
        if let receipt, let cipher = receipt.welcomeCipher { from = try? DelegationWelcome.open(cipher, secret: receipt.link.secret).from }
        else { from = nil }
        let value = saved.cipher.contains("|") ? (from ?? guest.senderLabel) : guest.hostLabel
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
    }
    func receive(_ cipher: String, guestID: String) async {
        guard app.canManageGuestAccess, app.guests.contains(where: { $0.id == guestID }) else { return }
        do {
            let existing = app.incomingMessages.first { $0.guestID == guestID && $0.cipher == cipher }
            let saved = existing ?? SavedMessage(guestID: guestID, cipher: cipher, receivedAt: Date())
            _ = try text(saved) // Authenticate/decrypt BEFORE persistence or any acknowledgement.
            if existing == nil {
                var updated = app.incomingMessages
                while updated.count >= 200 {
                    guard let i = updated.lastIndex(where: { $0.readAt != nil && $0.readAcknowledged }) else { throw BackupFailure.busy }
                    updated.remove(at: i)
                }
                updated.insert(saved, at: 0)
                try app.saveMessages(incoming: updated)
                AppSoundCenter.shared.play(.message)
            }
            try await acknowledge(saved.id)
        } catch { message = "Сообщение не удалось проверить или сохранить. Подтверждение чтения не отправлялось." }
    }
    func nextUnreadNotice() -> SavedMessage? {
        guard app.canManageGuestAccess, !app.hasTaskDialog else { return nil }
        return app.incomingMessages.reversed().first { $0.readAt == nil && (try? text($0)) != nil }
    }
    @discardableResult func markRead(_ id: String) -> Bool {
        guard app.canManageGuestAccess else { return false }
        do {
            guard let i = app.incomingMessages.firstIndex(where: { $0.id == id }) else { return false }
            _ = try text(app.incomingMessages[i])
            if app.incomingMessages[i].readAt == nil {
                var updated = app.incomingMessages; updated[i].readAt = Date()
                if updated[i].delegationWelcomeGroup != nil { updated[i].readAcknowledged = true }
                try app.saveMessages(incoming:updated)
            }
            message = nil; return true
        } catch {
            message = "Не удалось сохранить подтверждение чтения. Сообщение осталось на этом iPhone."; return false
        }
    }
    func read(_ id: String) async {
        guard markRead(id) else { return }
        do { try await acknowledge(id) }
        catch { message = "Не удалось сохранить подтверждение чтения. Сообщение осталось на этом iPhone." }
    }
    func retryAcknowledgements() async {
        guard app.canManageGuestAccess else { return }
        for row in app.incomingMessages where !row.deliveryAcknowledged || (row.readAt != nil && !row.readAcknowledged) {
            do { try await acknowledge(row.id) } catch { message = "Часть подтверждений пока не отправлена." }
        }
    }
    private func acknowledge(_ id: String) async throws {
        guard app.canManageGuestAccess, let saved = app.incomingMessages.first(where: { $0.id == id }),
              let guest = app.guests.first(where: { $0.id == saved.guestID }) else { return }
        _ = try text(saved)
        // Android ShareIn's initial message has no server read/delivery ACK.
        if saved.delegationWelcomeGroup != nil {
            guard !saved.deliveryAcknowledged || (saved.readAt != nil && !saved.readAcknowledged),
                  let index = app.incomingMessages.firstIndex(where: { $0.id == id }) else { return }
            var updated = app.incomingMessages; updated[index].deliveryAcknowledged = true
            if updated[index].readAt != nil { updated[index].readAcknowledged = true }
            try app.saveMessages(incoming: updated); return
        }
        let kind: MessageAcknowledgement = saved.readAt == nil ? .delivered : .read
        if (kind == .delivered && saved.deliveryAcknowledged) || (kind == .read && saved.readAcknowledged) { return }
        try await acknowledgements.acknowledgeMessage(invite: guest.invite, fingerprint: app.backupFingerprint(server: guest.invite.server), kind: kind,
            hash: GuestMessageCrypto.acknowledgementHash(saved.cipher))
        guard let i = app.incomingMessages.firstIndex(where: { $0.id == id }) else { return }
        var updated = app.incomingMessages
        updated[i].deliveryAcknowledged = true
        if kind == .read { updated[i].readAcknowledged = true }
        try app.saveMessages(incoming: updated)
    }
    func send(_ text: String, target: MessageTarget) async -> Bool {
        guard !busy, app.canManageGuestAccess else { return false }
        busy = true; message = nil
        defer { busy = false }
        var outgoing: OutgoingMessage?
        do {
            try GuestMessageCrypto.validateText(text)
            let cipher: String
            var passedSource: GuestInvite?
            var group: String?
            switch target {
            case .owner(let server, let key):
                cipher = try GuestMessageCrypto.seal(text, bundleKey: app.ownerMessageMaterial(server: server, keyID: key).bundleKey)
            case .passed(let id):
                guard let record = app.passedAccess.first(where: { $0.id == id }), let grp = record.group,
                      !record.parts.contains(where: { [.draft, .revoking, .revoked, .unavailable].contains($0.state) || $0.pendingEdit != nil }) else { throw BackupFailure.noAccess }
                var recipient: String?
                for part in record.parts {
                    guard let guest = app.guests.first(where: { $0.id == part.sourceID }) else { continue }
                    let data = try await delegation.delegate(invite: guest.invite, fingerprint: app.backupFingerprint(server: guest.invite.server), operation: .list, body: Data("{}".utf8))
                    let snapshot = try PassSnapshot.decode(data)
                    if let child = snapshot.children.first(where: { $0.group == grp }),
                       let sp = child.signPublic, let gp = child.guestPublic, let mac = child.mac,
                       child.objects == part.objects,
                       try DelegationProof.checkMAC(mac, secret: record.secret, group: grp, signPublic: sp, guestPublic: gp) {
                        recipient = gp; passedSource = guest.invite; group = grp; break
                    }
                }
                guard let recipient else { throw BackupFailure.noAccess }
                cipher = try GuestMessageCrypto.seal(text, recipientPublic: recipient)
            }
            guard app.canManageGuestAccess else { throw BackupFailure.busy }
            let saved = OutgoingMessage(id: UUID(), target: target, text: text, cipher: cipher, created: Date(), state: .sending)
            var updated = app.outgoingMessages
            updated.insert(saved, at: 0)
            try app.saveMessages(outgoing: Array(updated.prefix(100)))
            outgoing = saved
            switch target {
            case .owner(let server, let key):
                try await app.sendOwnerMessage(server: server, keyID: key, cipher: cipher)
            case .passed:
                guard let source = passedSource, let group else { throw BackupFailure.noAccess }
                let body = try JSONSerialization.data(withJSONObject: ["grp": group, "cipher": cipher], options: .sortedKeys)
                let response = try await delegation.delegate(invite: source, fingerprint: app.backupFingerprint(server: source.server), operation: .message, body: body)
                guard let row = try JSONSerialization.jsonObject(with: response) as? [String: Any], (row["ok"] as? NSNumber)?.boolValue == true else { throw BackupFailure.invalidPayload }
            }
            try update(saved.id, state: .accepted)
            message = "Сообщение принято сервером. Доставка и чтение пока не подтверждены."
            return true
        } catch {
            if let outgoing { try? update(outgoing.id, state: .uncertain) }
            message = outgoing == nil ? "Сообщение не отправлено. Не удалось проверить получателя или сохранить данные." : "Ответ отправки не подтверждён. Автоматического повтора не было."
            return false
        }
    }
    private func update(_ id: UUID, state: OutgoingMessage.State) throws {
        guard let i = app.outgoingMessages.firstIndex(where: { $0.id == id }) else { return }
        var updated = app.outgoingMessages; updated[i].state = state
        try app.saveMessages(outgoing: updated)
    }
}
