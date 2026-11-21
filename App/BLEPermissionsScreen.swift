import SwiftUI
import EntrixyCore

struct BLEPermissionsScreen: View {
    @EnvironmentObject private var app: AppModel
    let server: String
    let deviceID: UInt32
    var body: some View { BLEPermissionsContent(model: app.bleControl, server: server, deviceID: deviceID) }
}

private struct BLEPermissionsContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BLEOwnerControlModel
    let server: String
    let deviceID: UInt32
    private var owner: OwnerAccount? { app.owners.first { $0.server == server } }
    private var records: [BLERevocation] { (owner?.bleRevocations ?? []).filter { $0.deviceID == deviceID }.sorted { $0.version > $1.version } }
    var body: some View {
        List {
            Section {
                Button(ProductText.string("ios_ble_transfer_settings")) { Task { await model.deliverDecisions(server: server, deviceID: deviceID) } }.buttonStyle(PrimaryActionStyle())
                    .disabled(model.busy || app.ownerBusy || records.isEmpty)
                if model.busy { ProgressView(ProductText.string("ios_ble_transferring")) }
                if let text = model.deliveryMessages[deviceID] { Text(text).foregroundStyle(Brand.secondaryInk) }
            } footer: {
                Text(ProductText.string("ios_ble_delivery_proximity_hint"))
            }
            if records.isEmpty { Text(ProductText.string("ios_ble_access_changes_empty")).foregroundStyle(Brand.secondaryInk) }
            ForEach(records) { record in
                Section {
                    Text(guestLabel(record)).font(.headline)
                    Text(record.revoked ? ProductText.string("ios_ble_owner_deny") : ProductText.string("ios_ble_owner_allow"))
                    Text(status(record)).foregroundStyle(Brand.secondaryInk)
                    if record.controllerResult == 0x41 {
                        Button(ProductText.string("ios_ble_decision_new_revision")) { Task { await app.refreshOwnerBLEDecision(server: server, record: record) } }.buttonStyle(SecondaryActionStyle())
                            .disabled(model.busy || app.ownerBusy)
                    }
                }
            }
        }
        .navigationTitle(ProductText.string("ios_ble_access")).navigationBarTitleDisplayMode(.inline)
    }
    private func guestLabel(_ record: BLERevocation) -> String {
        owner?.issuedKeys?.first(where: { $0.guestID == Int(record.guestID) })?.label
            ?? owner?.delegatedKeys?.first(where: { $0.guestID == Int(record.guestID) })?.label
            ?? ProductText.string("ios_guest_pass")
    }
    private func status(_ record: BLERevocation) -> String {
        if record.applied { return ProductText.string("ios_controller_applied_confirmed") }
        if record.controllerResult == 0x41 { return ProductText.string("ios_ble_newer_decision_unknown") }
        return ProductText.string("ios_controller_transfer_pending")
    }
}
