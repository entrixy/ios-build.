import SwiftUI
import EntrixyCore

struct DraftGuestAutomationEditor: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var draft: GuestKeyDraft
    let server: String
    let objectID: UUID
    var body: some View {
        if let owner = model.owners.first(where: { $0.server == server }),
           let object = owner.objects?.first(where: { $0.id == objectID }), let number = object.numberID {
            let context = AutomationSettingsContext(destination: .draft(id: draft.id, objectID: object.id),
                label: (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "",
                isBLE: object.kind == "ble", incoming: false, issued: true,
                template: draft.templates[number] ?? AutomationTemplate(), ownerTemplate: nil,
                objectTemplate: try? AutomationTemplate(data: object.localPolicy), allowStream: draft.streams[number] ?? true,
                canEdit: model.canManageGuestAccess)
            AutomationEditor(destination: context.destination, contextOverride: context, saveOverride: { template in
                do { try template.validate(); draft.templates[number] = template; return true }
                catch { return false }
            })
        }
    }
}

/// GuestsScreen.ObjectAccessSheet, at the end of the selected object's row.
struct GuestObjectAccessEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var value: KeyObjectAccess
    var showNative = true
    var maxDepth = 5
    var maxPool = 50
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GuestAccessFields(value:$value,showNative:showNative,maxDepth:maxDepth,maxPool:maxPool)
                        .padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
                    Button(ProductText.string("btn_ok")) { dismiss() }.buttonStyle(PrimaryActionStyle())
                }.padding(DesignMetrics.pageInset)
            }.background(Color(uiColor: .systemGroupedBackground)).taskSheetTitle(title)
        }
    }
}

struct GuestBLELifetimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let label: String
    @Binding var seconds: UInt32
    private let keys = ["ttl_1h","ttl_2h","ttl_4h","ttl_8h","ttl_12h","ttl_1d","ttl_2d","ttl_3d","ttl_1w","ttl_2w","ttl_1mo"]
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(label).foregroundStyle(Brand.secondaryInk)
                let index = BLETokenLifetime.levels.firstIndex(of: seconds) ?? 5
                Text(ProductText.string(keys[index])).font(.title2).frame(maxWidth: .infinity).accessibilityIdentifier("guest-ble-lifetime-value")
                Slider(value: Binding(get: { Double(index) }, set: { seconds = BLETokenLifetime.levels[Int($0)] }),
                    in: 0...Double(BLETokenLifetime.levels.count-1), step: 1).accessibilityIdentifier("guest-ble-lifetime").tint(AppPalette.selected)
                HStack { Text(ProductText.string(keys[0])); Spacer(); Text(ProductText.string(keys.last!)) }.font(.footnote)
                Text(ProductText.string("guest_key_ttl_note")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                Spacer(minLength: 0)
            }.padding(DesignMetrics.pageInset).background(Color(uiColor: .systemGroupedBackground))
                .taskSheetTitle(ProductText.string("guest_key_ttl_title"))
                .sheetDismissFooter(ProductText.string("btn_close")) { dismiss() }
        }
    }
}

/// GuestCallEditor.kt: call reaction, then serve-during-call; webhook has only
/// its shared object-level server checkbox, never a meaningless call policy.
struct GuestInvocationEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    let objectID: UUID
    @Binding var preference: OwnerCallPreference
    @State private var warning = false
    @State private var working = false
    @State private var rememberedReaction = "confirm"
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    private var object: OwnerObject? { owner?.objects?.first { $0.id == objectID } }
    private var label: String { guard let owner, let object else { return "" }; return (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "" }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if object?.kind == "call" {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle(ProductText.string("guest_call_react_title"), isOn: Binding(get: { preference.reaction != "off" }, set: { enabled in
                                if enabled { preference.reaction = rememberedReaction }
                                else { rememberedReaction = preference.reaction; preference.reaction = "off" }
                            })).tint(AppPalette.selected).accessibilityIdentifier("guest-call-enabled")
                            if preference.reaction != "off" {
                                Text(ProductText.string("ios_guest_call_explicit"))
                                    .fixedSize(horizontal:false,vertical:true)
                                    .accessibilityIdentifier("guest-call-confirmation-policy")
                                Toggle(ProductText.string("ios_guest_call_notification"),isOn:Binding(get:{ preference.reaction == "notify" },set:{ enabled in
                                    if enabled {
                                        Task {
                                            if await OwnerPhoneNotifications.authorize() { preference.reaction = "notify"; rememberedReaction = "notify" }
                                            else { model.errorMessage = ProductText.string("ios_guest_call_notification_denied") }
                                        }
                                    } else { preference.reaction = "confirm"; rememberedReaction = "confirm" }
                                })).tint(AppPalette.selected).accessibilityIdentifier("guest-call-notification")
                            }
                        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        Text(ProductText.string("ios_call_guest_confirmation_required")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                    } else if object?.kind == "webhook" {
                        Toggle(ProductText.string("webhook_server_mode_title"), isOn: Binding(get: { object?.routing["webhook_mode"] == "server" }, set: { toServer in
                            if toServer { warning = true } else { Task { await setMode("phone") } }
                        })).tint(AppPalette.selected).padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            .disabled(working || model.ownerBusy || object?.pending != nil)
                    }
                }.padding(DesignMetrics.pageInset)
            }.background(Color(uiColor: .systemGroupedBackground))
                .taskSheetTitle(object?.kind == "call" ? ProductText.string("guest_call_title", label) : label)
                .task { if preference.reaction != "off" { rememberedReaction = preference.reaction } }
        }
        .sheetDismissFooter(ProductText.string("btn_close"),disabled:working) { dismiss() }
        .accessibilityHidden(warning)
        .overlay {
            if warning { WebhookServerModeConfirmation(cancel:{ warning = false },confirm:{ warning = false; Task { await setMode("server") } }) }
        }
    }
    private func setMode(_ mode: String) async {
        guard let owner, let object else { return }
        working = true; defer { working = false }
        do {
            var draft = try OwnerObjectEdit(object: object, masterKey: owner.masterKey); draft.webhookMode = mode
            _ = await model.updateOwnerObject(server: server, objectID: objectID, draft: draft)
        } catch { model.errorMessage = ProductText.string("ios_sending_mode_change_failed") }
    }
}

/// Same controls for per-object access and Guests / Presets.
struct GuestAccessFields: View {
    @Binding var value: KeyObjectAccess
    var showNative = true
    var maxDepth = 5
    var maxPool = 50
    private func change(native: Bool? = nil, depth: Int? = nil, pool: Int? = nil) {
        if let next = try? KeyObjectAccess(nativeOnly:native ?? value.nativeOnly,depth:min(maxDepth,max(0,depth ?? value.depth)),pool:min(maxPool,max(1,pool ?? value.pool))) { value = next }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            if showNative {
                Toggle(isOn:Binding(get:{ value.nativeOnly },set:{ change(native:$0) })) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(ProductText.string("guests_native_only"))
                        Text(ProductText.string("guests_native_only_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                }.tint(AppPalette.selected)
            }
            if maxDepth < 1 { Text(ProductText.string("delegate_stops_here")).foregroundStyle(Brand.secondaryInk) }
            else {
                Toggle(isOn:Binding(get:{ value.depth > 0 },set:{ change(depth:$0 ? 1 : 0) })) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(ProductText.string("guests_allow_delegate"))
                        Text(ProductText.string("guests_allow_delegate_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                }.tint(AppPalette.selected).accessibilityIdentifier("delegation-enabled")
                if value.depth > 0 {
                    Stepper(value:Binding(get:{ value.depth },set:{ change(depth:$0) }),in:1...maxDepth) {
                        HStack(spacing:12) {
                            Text(ProductText.string("ios_delegation_depth")).fixedSize(horizontal:false,vertical:true)
                            Spacer(minLength:8)
                            Text(String(value.depth)).bold().monospacedDigit().foregroundStyle(AppPalette.selected)
                                .frame(minWidth:20,alignment:.trailing)
                                .accessibilityIdentifier("delegation-depth-value")
                        }
                    }.tint(AppPalette.selected).accessibilityLabel(ProductText.string("ios_delegation_depth"))
                        .accessibilityValue(String(value.depth)).accessibilityIdentifier("delegation-depth")
                    if maxPool > 1 {
                        VStack(alignment:.leading,spacing:5) {
                            Text(ProductText.string("guests_pass_pool"))
                            Text(ProductText.string("guests_pass_pool_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                        }
                        Stepper(value:Binding(get:{ value.pool },set:{ change(pool:$0) }),in:1...maxPool) {
                            HStack(spacing:12) {
                                Text(ProductText.string("ios_delegation_key_count")).fixedSize(horizontal:false,vertical:true)
                                Spacer(minLength:8)
                                Text(String(value.pool)).bold().monospacedDigit().foregroundStyle(AppPalette.selected)
                                    .frame(minWidth:20,alignment:.trailing)
                                    .accessibilityIdentifier("delegation-pool-value")
                            }
                        }.tint(AppPalette.selected).accessibilityLabel(ProductText.string("ios_delegation_key_count"))
                            .accessibilityValue(String(value.pool)).accessibilityIdentifier("delegation-pool")
                    }
                }
            }
        }.onAppear { change() }
    }
}
