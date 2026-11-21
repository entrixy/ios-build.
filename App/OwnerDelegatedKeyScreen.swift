import SwiftUI
import EntrixyCore

struct OwnerDelegatedKeyScreen: View {
    @EnvironmentObject private var app: AppModel
    let server: String
    let keyID: UUID
    @State private var revoking = false
    @State private var retrying = false
    private var owner: OwnerAccount? { app.owners.first { $0.server == server } }
    private var key: OwnerDelegatedKey? { owner?.delegatedKeys?.first { $0.id == keyID } }
    var body: some View {
        List {
            if let key {
                Section {
                    Text(key.label).font(.headline)
                    if let message = app.ownerMessages[server] { Text(ProductText.systemMessage(message)).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    Text(ownerDelegatedStatus(key)).foregroundStyle(Brand.secondaryInk)
                    if let message = app.ownerDelegationMessages[keyID] { Text(ProductText.systemMessage(message)).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    KeyValueRow(title: ProductText.string("ble_server_label"), value: server)
                }
                Section(ProductText.string("settings_tab_objects")) {
                    ForEach(key.numberIDs, id: \.self) { id in
                        Text(objectLabel(id))
                    }
                }
                Section {
                    Button(ProductText.string("ios_refresh_data")) { Task { await app.refreshOwners() } }.buttonStyle(SecondaryActionStyle()).disabled(app.ownerBusy)
                    if key.state == .awaiting && key.revocationPending != true {
                        if key.sent {
                            Button(ProductText.string("ios_bundle_retry")) { retrying = true }.buttonStyle(PrimaryActionStyle()).disabled(app.ownerBusy)
                        } else {
                            Button(ProductText.string("ios_delegated_access_confirm")) { Task { await app.approveDelegatedKey(server: server, keyID: keyID) } }.buttonStyle(PrimaryActionStyle()).disabled(app.ownerBusy)
                        }
                    }
                    if key.state != .revoked && key.revocationSent != true {
                        Button(ProductText.string("ios_access_revoke"), role: .destructive) { revoking = true }.buttonStyle(SecondaryActionStyle()).disabled(app.ownerBusy)
                    }
                } footer: { Text(ProductText.string("ios_bundle_vouch_hint")) }
            } else { Text(ProductText.string("ios_delegated_key_unavailable")).foregroundStyle(Brand.secondaryInk) }
        }
        .navigationTitle(ProductText.string("ios_delegated_access")).navigationBarTitleDisplayMode(.inline)
        .appConfirmationDialog(ProductText.string("ios_access_revoke_title"),message:ProductText.string("ios_access_revoke_recipient_chain"),actionTitle:ProductText.string("ios_access_revoke"),destructive:true,isPresented:$revoking) {
            Task { await app.revokeDelegatedKey(server: server, keyID: keyID) }
        }
        .appConfirmationDialog(ProductText.string("ios_bundle_transfer_title"),message:ProductText.string("ios_bundle_same_retry_hint"),actionTitle:ProductText.string("ios_bundle_transfer"),isPresented:$retrying) {
            Task { await app.approveDelegatedKey(server: server, keyID: keyID, retry: true) }
        }
    }
    private func objectLabel(_ id: Int) -> String {
        guard let owner, let object = owner.objects?.first(where: { $0.numberID == id }) else { return ProductText.string("ios_obj_number_fmt",id) }
        return (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? ProductText.string("ios_obj_number_fmt",id)
    }
}
func ownerDelegatedStatus(_ key: OwnerDelegatedKey) -> String {
    if key.revocationPending == true { return ProductText.string("ios_revoke_server_pending") }
    switch key.state {
    case .awaiting: return key.sent ? ProductText.string("ios_bundle_server_pending") : ProductText.string("ios_vouch_verified_bundle_required")
    case .ready: return ProductText.string("ios_access_active")
    case .unavailable: return ProductText.string("ios_access_unconfirmed_or_paused")
    case .revoked: return ProductText.string("ios_access_revoked")
    }
}
