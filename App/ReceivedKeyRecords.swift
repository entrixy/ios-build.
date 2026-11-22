import Foundation
import SwiftUI
import EntrixyCore

/// Android Settings keys: one human key may contain several owner parts.
/// These rows never authorize, combine or replace the underlying signing keys.
struct ReceivedKeyRecord: Identifiable {
    let id: String
    let members: [SavedGuest]
    let imported: [AndroidGuestMigration]
    let pending: DelegationRedemption?
    let primary: SavedGuest?
    let title: String
    var objectNames: String { members.flatMap(\.objects).map(\.label).joined(separator: ", ") }
}

extension AppModel {
    var receivedKeyRecords: [ReceivedKeyRecord] {
        var receiptForGuest: [String: String] = [:], receiptByID: [String: ReceivedDelegation] = [:]
        for receipt in receivedDelegations {
            receiptByID[receipt.id] = receipt
            for id in receipt.guestIDs where receiptForGuest[id] == nil { receiptForGuest[id] = receipt.id }
        }
        let saved = Dictionary(grouping: guests) { receiptForGuest[$0.id] ?? $0.keyGroup ?? $0.id }
        let imports = Dictionary(grouping: androidPendingGuests) { $0.groupID ?? $0.id }
        let pending = Dictionary(delegations.map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        var seen = Set<String>(), order: [String] = []
        let candidates = guests.map { receiptForGuest[$0.id] ?? $0.keyGroup ?? $0.id }
            + androidPendingGuests.map { $0.groupID ?? $0.id } + delegations.map(\.id)
        for id in candidates where seen.insert(id).inserted { order.append(id) }
        var result: [ReceivedKeyRecord] = []
        for (offset,id) in order.enumerated() {
            let members = saved[id] ?? [], imported = imports[id] ?? [], waiting = pending[id], receipt = receiptByID[id]
            let primary = members.first { !$0.paused && connection(for: $0.id) == .connected }
                ?? members.first { !$0.paused } ?? members.first
            func firstText(_ values: [String?]) -> String? { values.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
            let from: String?
            if let receipt, let cipher = receipt.welcomeCipher { from = try? DelegationWelcome.open(cipher, secret: receipt.link.secret).from }
            else if let waiting, let cipher = waiting.welcomeCipher { from = try? DelegationWelcome.open(cipher, secret: waiting.link.secret).from }
            else { from = nil }
            let override = firstText(members.map(\.localKeyLabel) + imported.map(\.labelOverride))
            let sender = firstText([from] + members.map(\.senderLabel) + imported.map(\.senderLabel))
            let host = firstText([primary?.hostLabel] + members.map(\.hostLabel) + imported.map { Optional($0.label) })
            let number = members.first?.sequenceNumber ?? imported.first?.localID ?? offset + 1
            let title = override ?? sender ?? host ?? ProductText.string("settings_connection_num",number)
            result.append(ReceivedKeyRecord(id: id, members: members, imported: imported, pending: waiting, primary: primary, title: title))
        }
        return result
    }
}

struct ReceivedKeySettingsRow: View {
    @EnvironmentObject private var model: AppModel
    let record: ReceivedKeyRecord
    @ObservedObject var backups: BackupManager
    @ObservedObject var inbox: DelegationInbox
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "link").foregroundStyle(Brand.ink).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(record.title).font(.headline)
                if let primary = record.primary { ConnectionLabel(guestID: primary.id, paused: primary.paused) }
                else { Text(ProductText.string("guests_key_awaiting_bundle")).font(.footnote).foregroundStyle(Brand.secondaryInk) }
                if !record.objectNames.isEmpty { Text(record.objectNames).font(.caption).foregroundStyle(Brand.secondaryInk) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            GuestIconButton("trash", label: ProductText.string("btn_delete"), destructive: true, action: remove)
                .disabled(!model.canManageGuestAccess || model.busy || model.ownerBusy)
                .accessibilityIdentifier("received-key-delete-" + record.id)
        }
            if let issue = record.members.compactMap({ model.guestConnectionProblems[$0.id] }).first {
                Text(ProductText.string(issue)).font(.footnote).foregroundStyle(AppPalette.destructive)
            }
            if !record.imported.isEmpty || record.pending != nil {
                Button(ProductText.string("btn_retry")) {
                    Task {
                        for source in record.imported { await backups.recoverImportedGuest(source.id) }
                        if let pending = record.pending {
                            if pending.sent { await inbox.check(pending.id) } else { await inbox.send(pending.id) }
                        }
                    }
                }.buttonStyle(SecondaryActionStyle()).disabled(backups.busy || inbox.busy || model.busy || model.ownerBusy || !model.canManageGuestAccess)
            }
        }.padding(.vertical, 8).accessibilityElement(children: .contain)
            .accessibilityIdentifier("received-key-" + (record.members.first?.id ?? record.id))
    }
}
