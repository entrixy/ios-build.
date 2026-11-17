import SwiftUI
import EntrixyCore

/// Android System → servers → home networks, using the shared native controls.
struct NetworkPrivacySettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var sensors: AutomationSensors
    private var current: PrivacyNetwork? {
        guard let network = sensors.network else { return nil }
        return (try? PrivacyNetwork(ssid:network.ssid,bssid:network.bssid)) ?? (try? PrivacyNetwork(ssid:network.ssid))
    }
    private var supported: Bool { if #available(iOS 17.0,*) { return true }; return false }
    var body: some View {
        Group {
            Section {
                Text(ProductText.string("ios_privacy_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                Text(ProductText.string(supported ? "ios_privacy_transport" : "ios_privacy_unavailable")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                if supported {
                    Toggle(ProductText.string("ios_privacy_cellular"),isOn:Binding(get:{ model.networkPrivacy.cellularAuthorized },set:{ value in
                        var draft = model.networkPrivacy; draft.cellularAuthorized = value
                        model.setNetworkPrivacy(draft)
                    })).accessibilityIdentifier("privacy-cellular-consent")
                    Text(ProductText.string("ios_privacy_cellular_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                }
            } header: { Text(ProductText.string("privacy_net_section")) }
            if let current {
                if !model.networkPrivacy.own.contains(where:{ $0.ssid.caseInsensitiveCompare(current.ssid) == .orderedSame }) {
                    Section {
                        VStack(alignment:.leading,spacing:12) {
                            Text(ProductText.string("privacy_net_current",current.ssid))
                            Button(ProductText.string("privacy_net_block")) { model.networkPrivacyPrompt = current }
                                .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("privacy-add-current")
                        }.actionListRow()
                    }
                }
            } else {
                Section {
                    Text(ProductText.string("ios_privacy_unknown_wifi")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                }
                if sensors.locationAuthorization == .notDetermined {
                    Section {
                        Button(ProductText.string("ios_privacy_wifi_permission")) { sensors.requestNetworkAccess() }
                            .buttonStyle(SecondaryActionStyle()).actionListRow()
                    }
                }
            }
            if !model.networkPrivacy.own.isEmpty {
                Section {
                    ForEach(model.networkPrivacy.own,id:\.comparisonKey) { network in
                        HStack(spacing:12) {
                            Text(network.ssid).frame(maxWidth:.infinity,alignment:.leading)
                            Button(ProductText.string("btn_delete"),role:.destructive) { remove(network) }
                                .buttonStyle(SecondaryActionStyle()).fixedSize(horizontal:true,vertical:false)
                                .accessibilityIdentifier("privacy-remove-"+GuestCrypto.hash(Data(network.comparisonKey.utf8)))
                        }.actionListRow()
                    }
                } header: { Text(ProductText.string("privacy_net_blocked_title")) }
            }
        }.disabled(!model.canManageGuestAccess || model.busy || model.ownerBusy)
            .task { sensors.refreshNetwork() }
    }
    private func remove(_ network: PrivacyNetwork) {
        var draft = model.networkPrivacy
        draft.own.removeAll { $0.comparisonKey == network.comparisonKey }
        model.setNetworkPrivacy(draft)
    }
}

struct NetworkPrivacyDialog: View {
    @EnvironmentObject private var model: AppModel
    let network: PrivacyNetwork
    private var supported: Bool { if #available(iOS 17.0,*) { return true }; return false }
    var body: some View {
        AppConfirmationDialog(title:ProductText.string("privacy_net_confirm_title",network.ssid),
            message:ProductText.string(supported ? "ios_privacy_transport" : "ios_privacy_unavailable"),
            actionTitle:ProductText.string("privacy_net_block"),cancel:{ model.networkPrivacyPrompt = nil },confirm:{
                var draft = model.networkPrivacy
                draft.own.removeAll { $0.ssid.caseInsensitiveCompare(network.ssid) == .orderedSame }
                draft.own.append(network)
                if model.setNetworkPrivacy(draft) { model.networkPrivacyPrompt = nil }
            })
        .disabled(!model.canManageGuestAccess || model.busy || model.ownerBusy)
    }
}
