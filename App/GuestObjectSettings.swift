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
                    Button(ProductText.string("btn_ok")) { dismiss() }.buttonStyle(PrimaryActionStyle())
                }.padding(DesignMetrics.pageInset)
            }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
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
                    in: 0...Double(BLETokenLifetime.levels.count-1), step: 1).accessibilityIdentifier("guest-ble-lifetime")
                HStack { Text(ProductText.string(keys[0])); Spacer(); Text(ProductText.string(keys.last!)) }.font(.footnote)
                Text(ProductText.string("guest_key_ttl_note")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                Spacer(minLength: 0)
            }.padding(DesignMetrics.pageInset).background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(ProductText.string("guest_key_ttl_title")).navigationBarTitleDisplayMode(.inline)
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
    @State private var rememberedReaction = "auto"
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
                            })).accessibilityIdentifier("guest-call-enabled")
                            if preference.reaction != "off" {
                                ForEach(["confirm","notify","auto"], id: \.self) { mode in
                                    Button {
                                        if mode == "notify" {
                                            Task {
                                                if await OwnerPhoneNotifications.authorize() { rememberedReaction = mode; preference.reaction = mode }
                                                else { model.errorMessage = "Разрешите уведомления Entrixy в настройках iPhone." }
                                            }
                                        } else { rememberedReaction = mode; preference.reaction = mode }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: preference.reaction == mode ? "largecircle.fill.circle" : "circle")
                                            Text(ProductText.string("guest_call_react_" + mode)).frame(maxWidth: .infinity, alignment: .leading)
                                        }.foregroundStyle(Brand.ink).frame(minHeight: 48).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityIdentifier("guest-call-reaction-" + mode)
                                }
                                Divider()
                                Toggle(isOn: $preference.serveDuringCall) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(ProductText.string("guest_call_serve_title"))
                                        Text(ProductText.string("guest_call_serve_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                                    }
                                }
                            }
                        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        Text("iOS всегда запрашивает системное подтверждение звонка. Вызов из фона недоступен.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    } else if object?.kind == "webhook" {
                        Toggle(ProductText.string("webhook_server_mode_title"), isOn: Binding(get: { object?.routing["webhook_mode"] == "server" }, set: { toServer in
                            if toServer { warning = true } else { Task { await setMode("phone") } }
                        })).padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            .disabled(working || model.ownerBusy || object?.pending != nil)
                    }
                }.padding(DesignMetrics.pageInset)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(object?.kind == "call" ? ProductText.string("guest_call_title", label) : label).navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(ProductText.string("btn_close"), disabled: working) { dismiss() }
                .task { if preference.reaction != "off" { rememberedReaction = preference.reaction } }
                .accessibilityHidden(warning)
                .overlay {
                    if warning { WebhookServerModeConfirmation(cancel: { warning = false }, confirm: { warning = false; Task { await setMode("server") } }) }
                }
        }
    }
    private func setMode(_ mode: String) async {
        guard let owner, let object else { return }
        working = true; defer { working = false }
        do {
            var draft = try OwnerObjectEdit(object: object, masterKey: owner.masterKey); draft.webhookMode = mode
            _ = await model.updateOwnerObject(server: server, objectID: objectID, draft: draft)
        } catch { model.errorMessage = "Не удалось изменить режим отправки." }
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
                }
            }
            if maxDepth < 1 { Text(ProductText.string("delegate_stops_here")).foregroundStyle(Brand.secondaryInk) }
            else {
                Toggle(isOn:Binding(get:{ value.depth > 0 },set:{ change(depth:$0 ? 1 : 0) })) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(ProductText.string("guests_allow_delegate"))
                        Text(ProductText.string("guests_allow_delegate_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                }
                if value.depth > 0 {
                    Stepper(value:Binding(get:{ value.depth },set:{ change(depth:$0) }),in:1...maxDepth) { Text(String(value.depth)) }
                    if maxPool > 1 {
                        VStack(alignment:.leading,spacing:5) {
                            Text(ProductText.string("guests_pass_pool"))
                            Text(ProductText.string("guests_pass_pool_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                        }
                        Stepper(value:Binding(get:{ value.pool },set:{ change(pool:$0) }),in:1...maxPool) { Text(String(value.pool)) }
                    }
                }
            }
        }.onAppear { change() }
    }
}
