import SwiftUI
import EntrixyCore

struct DelegationInboxScreen: View {
    @EnvironmentObject private var app: AppModel
    var manager: DelegationInbox? = nil
    var body: some View { DelegationInboxContent(manager: manager ?? app.delegationInbox) }
}
private struct DelegationInboxContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: DelegationInbox
    @State private var removing: String?
    var body: some View {
        List {
            if let message = manager.message { Section { Text(ProductText.systemMessage(message)).foregroundStyle(Brand.secondaryInk) } }
            if app.delegations.isEmpty { Text(ProductText.string("ios_pending_keys_empty")).foregroundStyle(Brand.secondaryInk) }
            if !app.receivedDelegations.isEmpty {
                Section(ProductText.string("ios_transfers_accepted")) {
                    ForEach(app.receivedDelegations) { receipt in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(receipt.link.server).font(.headline)
                            Text(ProductText.string("ios_parts_installed_fmt",receipt.guestIDs.count)).foregroundStyle(Brand.secondaryInk)
                        }
                    }
                    Button(ProductText.string("ios_check_new_parts")) {
                        Task { await manager.refreshAdditionalParts(); await manager.checkAll() }
                    }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                }
            }
            ForEach(app.delegations) { pending in
                Section {
                    KeyValueRow(title: ProductText.string("ble_server_label"), value: pending.link.server)
                    KeyValueRow(title: ProductText.string("ios_confirmation_pending"), value: String(pending.parts.count - pending.completedCodes.count))
                    if !pending.sent {
                        Button(ProductText.string("ios_acceptance_send")) { Task { await manager.send(pending.id) } }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                    }
                    Button(ProductText.string("ios_confirmation_check")) { Task { await manager.check(pending.id) } }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                    Button(ProductText.string("ios_pending_remove_local"), role: .destructive) { removing = pending.id }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                } footer: { Text(ProductText.string("ios_acceptance_participants_hint")) }
            }
        }
        .navigationTitle(ProductText.string("ios_pending_keys")).navigationBarTitleDisplayMode(.inline)
        .appConfirmationDialog(ProductText.string("ios_recipient_remove_title"),message:ProductText.string("ios_recipient_remove_hint"),actionTitle:ProductText.string("ios_remove_from_iphone"),destructive:true,isPresented:Binding(get:{ removing != nil },set:{ if !$0 { removing = nil } })) {
            if let id = removing { app.removePendingDelegation(id) }; removing = nil
        }
    }
}

struct DelegationImportSection: View {
    @ObservedObject var manager: DelegationInbox
    let input: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = manager.message { Text(ProductText.systemMessage(message)).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
            if let pending = manager.preview {
                Text(ProductText.string("ios_delegated_access")).font(.headline)
                KeyValueRow(title: ProductText.string("ble_server_label"), value: pending.link.server)
                KeyValueRow(title: ProductText.string("ios_key_parts"), value: String(pending.parts.count))
                Text(ProductText.string("ios_accept_transfer_hint")).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                Button(ProductText.string("ios_transfer_accept")) { Task { await manager.accept() } }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy)
            } else {
                Button { Task { await manager.inspect(input) } } label: {
                    HStack { if manager.busy { ProgressView() }; Text(ProductText.string("ios_delegated_access_check")) }
                }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy)
            }
        }
        .onChange(of: input) { _ in manager.clearPreview() }
        .onDisappear { manager.clearPreview() }
    }
}
