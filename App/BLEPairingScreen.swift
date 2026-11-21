import SwiftUI
import EntrixyCore

struct BLEPairingScreen: View {
    @EnvironmentObject private var app: AppModel
    let server: String
    var initialLabel = ""
    var manager: BLEPairingModel? = nil
    var completion: ((ObjectReference?) -> Void)? = nil
    var body: some View { BLEPairingContent(model: manager ?? app.blePairing, server: server, label: initialLabel, completion: completion).environmentObject(app) }
}

private struct BLEPairingContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BLEPairingModel
    let server: String
    @State private var label: String
    let completion: ((ObjectReference?) -> Void)?
    init(model: BLEPairingModel, server: String, label: String = "", completion: ((ObjectReference?) -> Void)? = nil) {
        self.model = model; self.server = server; self.completion = completion; _label = State(initialValue: label)
    }
    @State private var selected: BLEDiscovery?
    private var records: [BLEPairingRecord] { app.owners.first(where: { $0.server == server })?.blePairings ?? [] }
    var body: some View {
        Form {
            Section {
                AppField(ProductText.string("ios_obj_name")) {
                    TextField(ProductText.string("ios_obj_name"), text: $label)
                }
                Text(ProductText.string("ios_ble_pairing_hint"))
                    .font(.footnote).foregroundStyle(Brand.secondaryInk)
                Button(ProductText.string("ios_ble_find_controllers")) { Task { await model.scan() } }.buttonStyle(PrimaryActionStyle()).disabled(model.busy)
                ForEach(model.discoveries) { discovery in
                    Button { selected = discovery } label: {
                        HStack {
                            Text(discovery.name).foregroundStyle(Brand.ink)
                            Spacer()
                            Text("\(discovery.rssi) dBm").foregroundStyle(Brand.secondaryInk)
                        }
                    }.buttonStyle(SecondaryActionStyle()).disabled(model.busy || app.ownerBusy || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || records.contains(where: { $0.peripheralID == discovery.id }))
                }
            } header: { Text(ProductText.string("ios_ble_pairing_new")) }
            if model.busy { Section { ProgressView("Bluetooth…") } }
            if let message = model.message { Section { Text(ProductText.systemMessage(message)).foregroundStyle(Brand.secondaryInk) } }
            ForEach(records) { record in
                Section {
                    Text(record.label).font(.headline)
                    Text(status(record)).foregroundStyle(Brand.secondaryInk)
                    if record.phase == .confirmed {
                        NavigationLink(ProductText.string("ios_ble_guest_access")) { BLEPermissionsScreen(server: server, deviceID: record.deviceID) }
                    }
                    if record.phase == .prepared {
                        Button(ProductText.string("ios_ble_send_saved_pairing")) { Task { await model.sendPrepared(pairingID: record.id, server: server) } }.buttonStyle(PrimaryActionStyle()).disabled(model.busy || app.ownerBusy)
                    }
                    if record.objectID == nil, record.phase != .prepared {
                        Button(ProductText.string("ios_ble_check_pairing")) { Task { await model.check(pairingID: record.id, server: server) } }.buttonStyle(SecondaryActionStyle()).disabled(model.busy || app.ownerBusy)
                    }
                    if record.phase == .confirmed, record.objectID == nil {
                        Button(ProductText.string("ios_add_to_server")) {
                            Task {
                                _ = await app.registerPairedBLE(server: server, pairingID: record.id)
                                // Complete only this pairing's durable object, including an
                                // uncertain registration; never select an unrelated saved peer.
                                if let id = records.first(where: { $0.id == record.id })?.objectID {
                                    completion?(.owned(server: server, objectID: id))
                                }
                            }
                        }.buttonStyle(PrimaryActionStyle())
                            .disabled(model.busy || app.ownerBusy)
                    }
                } header: { Text(ProductText.string("ios_ble_saved_pairing")) }
            }
        }
        .navigationTitle(ProductText.string("ios_ble_controller")).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible,for:.navigationBar)
        .onDisappear { if model.busy { model.suspend() } }
        .appConfirmationDialog(ProductText.string("ios_ble_pairing_confirm_title"),message:ProductText.string("ios_ble_pairing_identity_hint"),actionTitle:ProductText.string("ios_ble_pair"),isPresented:Binding(get:{ selected != nil },set:{ if !$0 { selected = nil } })) {
            if let selected { let id = selected.id; self.selected = nil
                Task { await model.pair(discoveryID:id,server:server,label:label) }
            }
        }
    }
    private func status(_ record: BLEPairingRecord) -> String {
        if record.objectID != nil { return ProductText.string("ios_ble_object_saved_hint") }
        switch record.phase {
        case .prepared: return ProductText.string("ios_ble_pairing_prepared_hint")
        case .sent: return ProductText.string("ios_ble_pairing_unknown_hint")
        case .confirmed: return ProductText.string("ios_ble_pairing_verified_hint")
        }
    }
}
