import SwiftUI
import EntrixyCore

/// Kept for existing recovery routes; System embeds the same server rows.
struct OwnerServersScreen: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List { ServerSettingsSection() }.scrollContentBackground(.hidden).compactListSections()
            .background(Color(uiColor:.systemGroupedBackground))
            .navigationTitle(ProductText.string("server_section")).navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refreshOwners() }
    }
}

/// Existing debug/company callers share the real editor instead of a second form.
struct AddOwnerServerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: ServerSettingsPrompt
    init(initialServer: String = "entrixy.com") { _prompt = State(initialValue:ServerSettingsPrompt(action:.configure(nil,initial:initialServer))) }
    var body: some View { ServerSettingsDialog(prompt:prompt,completion:{ dismiss() }) }
}

struct OwnerObjectsScreen: View {
    @EnvironmentObject private var model: AppModel
    let server: String
    var body: some View {
        List { OwnerObjectRows(server: server) }.compactListSections()
            .navigationTitle("Мои объекты").navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refreshOwners() }
    }
}
struct OwnerObjectRows: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    let server: String
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    var body: some View {
        Group {
            if let owner {
                Section {
                    ObjectSettingsRows(entries: model.catalogObjects().filter {
                        if case let .owned(account, _) = $0 { return account.server == server }
                        return false
                    })
                    if (owner.objects ?? []).isEmpty { Text("Пока нет добавленных объектов").foregroundStyle(Brand.secondaryInk) }
                }
                Section {
                    Button { adding = true } label: { Label(ProductText.string("settings_add_object"), systemImage: "plus") }
                        .buttonStyle(SecondaryActionStyle())
                        .disabled(model.ownerBusy || owner.registrationPending)
                        .actionListRow()
                }
                if !(owner.bleArchivedObjects ?? []).isEmpty {
                    Section {
                        ForEach(owner.bleArchivedObjects ?? []) { object in
                            if let did = object.bleDeviceID {
                                NavigationLink { BLEPermissionsScreen(server: server, deviceID: did) } label: {
                                    Text((try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Bluetooth-контроллер")
                                }
                            }
                        }
                    } header: { Text("Bluetooth после удаления объекта") } footer: {
                        Text("Секрет привязки сохранён, чтобы доставить контроллеру изменения доступа.")
                    }
                }
                if let snapshot = model.ownerSnapshots[server], snapshot.objectCount > (owner.objects ?? []).filter({ $0.numberID != nil }).count {
                    Section { Text("На сервере есть объекты, ключи которых отсутствуют на этом iPhone. Для их настройки нужна резервная копия владельца.").foregroundStyle(Brand.secondaryInk) }
                }
            }
        }
        .sheet(isPresented: $adding) { AddOwnerObjectScreen(server: server) }
    }
}

struct AddOwnerObjectScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    @State private var label = ""
    @State private var kind = "call"
    @State private var phone = ""
    @State private var url = ""
    @State private var secret = PhoneWebhook.newSecret()
    @State private var webhookMode = "phone"
    @State private var serverModeWarning = false
    @State private var webhookToggle = false
    @State private var claimMode = false
    @State private var claimCode = ""
    @State private var pairing = false
    @State private var contacts = false
    @FocusState private var editingName: Bool
    var embedded = false
    var completion: ((ObjectReference?) -> Void)? = nil
    private let incomingClaim: Bool
    init(server: String, initialClaimCode: String? = nil, embedded: Bool = false, completion: ((ObjectReference?) -> Void)? = nil) {
        self.server = server; self.embedded = embedded; self.completion = completion
        incomingClaim = initialClaimCode != nil
        _kind = State(initialValue:initialClaimCode == nil ? "call" : "device")
        _claimMode = State(initialValue:initialClaimCode != nil)
        _claimCode = State(initialValue:initialClaimCode ?? "")
    }
    private var destinationServer: String { incomingClaim && !(kind == "device" && claimMode) ? model.selectedOwnerServer : server }
    private var complete: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (kind == "ble" || (kind == "device" ? !claimMode || !claimCode.isEmpty :
            (kind == "call" ? !phone.isEmpty : !url.isEmpty && !secret.isEmpty)))
    }
    var body: some View {
        Group { if embedded { fields } else { NavigationStack { fields } } }
    }
    private var fields: some View {
        Form {
            Section {
                ForEach(["call", "webhook", "device", "ble"], id: \.self) { value in
                    Button { kind = value } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind == value ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Brand.ink)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ProductText.string("add_object_type_" + value)).foregroundStyle(Brand.ink)
                                Text(ProductText.string("add_object_type_" + value + "_desc"))
                                    .font(.footnote).foregroundStyle(Brand.secondaryInk)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("owner-object-type-" + value)
                        .accessibilityAddTraits(kind == value ? .isSelected : [])
                }
            } header: { Text(ProductText.string("add_object_type_title")).accessibilityIdentifier("owner-object-kind") }
            Section {
                AppField(ProductText.string("add_object_name")) {
                    TextField(ProductText.string("add_object_name_placeholder"), text: $label)
                        .accessibilityLabel(ProductText.string("add_object_name"))
                        .focused($editingName).submitLabel(.done).onSubmit { editingName = false }
                        .onChange(of: label) { label = String($0.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "").prefix(64)) }
                }
                if kind == "call" {
                    AppField(ProductText.string("add_object_phone")) {
                        TextField(ProductText.string("add_object_phone_placeholder"), text: $phone).keyboardType(.phonePad)
                            .accessibilityLabel(ProductText.string("add_object_phone"))
                    }
                } else if kind == "webhook" {
                    WebhookConfigurationFields(url: $url, secret: $secret, mode: $webhookMode, toggles: $webhookToggle, requestServerMode: { serverModeWarning = true })
                } else if kind == "ble" {
                    Text(ProductText.string("ble_pair_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                } else {
                    Picker(ProductText.string("add_object_type_device"), selection: $claimMode) {
                        Text(ProductText.string("add_object_device_new")).tag(false)
                        Text(ProductText.string("add_object_device_claim")).tag(true)
                    }.pickerStyle(.inline)
                    if claimMode {
                        AppField(ProductText.string("add_object_device_claim_code")) {
                            TextField("A1B2C3D4", text: $claimCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .accessibilityIdentifier("device-claim-code")
                        }
                    }
                }
                if incomingClaim || model.owners.filter({ !$0.registrationPending }).count > 1 {
                    Text(ProductText.string("object_server") + ": " + destinationServer).font(.footnote).foregroundStyle(Brand.secondaryInk)
                }
            }
            if kind == "call" {
                Section {
                    Button { contacts = true } label: { Label(ProductText.string("add_object_from_contacts"), systemImage: "person.crop.circle") }
                        .buttonStyle(SecondaryActionStyle()).actionListRow()
                }
                PhoneHangupLimitation(hangupSeconds: 0)
            }
            if let owner = model.owners.first(where: { $0.server == destinationServer }), owner.registrationPending {
                Section {
                    Text(model.ownerMessages[server] ?? "Доступ владельца ещё не подтверждён.").foregroundStyle(Brand.secondaryInk)
                    Button(ProductText.string("server_edit")) {
                        finish(nil)
                        model.settingsRequest = .system
                        model.serverPrompt = ServerSettingsPrompt(action:.configure(destinationServer,initial:destinationServer))
                    }.buttonStyle(SecondaryActionStyle()).actionListRow()
                }
            }
            Section {
                Button { Task { await save() } } label: {
                    ActionButtonLabel(title: ProductText.string("btn_save"), busy: model.ownerBusy)
                }.buttonStyle(PrimaryActionStyle()).actionListRow().disabled(!complete || model.ownerBusy)
            }
        }
        .disabled(model.ownerBusy)
        .navigationTitle(ProductText.string("add_object_title")).navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if StageTwoCapture.current == .addObject { kind = "ble"; label = "Новый BLE-объект" }
            #endif
        }
        .navigationDestination(isPresented: $pairing) {
            BLEPairingScreen(server: destinationServer, initialLabel: label, completion: { target in finish(target) })
                .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }
        }
        .sheet(isPresented: $contacts) {
            ObjectPhoneContactPicker(selected: { number, name in
                phone = number.filter { !" -()".contains($0) }
                if label.isEmpty { label = String(name.prefix(64)) }
                contacts = false
            }, cancelled: { contacts = false })
        }
        .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }
        .appMessageDialog("Entrixy",message:model.errorMessage ?? "",actionTitle:"Понятно",isPresented:Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }))
        .accessibilityHidden(serverModeWarning)
        .overlay {
            if serverModeWarning {
                WebhookServerModeConfirmation(cancel: { serverModeWarning = false }, confirm: { webhookMode = "server"; serverModeWarning = false })
            }
        }
    }
    private func save() async {
        guard complete, !model.ownerBusy, !model.busy else { return }
        let server = destinationServer
        // Opening a form never registers a replacement owner identity.
        if !model.owners.contains(where: { $0.server == server }) {
            guard await model.addOwner(server: server, accessCode: "") else { return }
        }
        guard model.owners.first(where: { $0.server == server })?.credentials != nil else {
            model.errorMessage = "Сначала завершите сохранённую регистрацию владельца. Повторная регистрация не отправлялась."
            return
        }
        if kind == "ble" { pairing = true; return }
        let before = Set(model.owners.first(where: { $0.server == server })?.objects?.map(\.id) ?? [])
        let result = await model.createOwnerObject(server: server, label: label, kind: kind, phone: phone,
            url: url, secret: secret, claimCode: claimCode, registerDevice: kind == "device" && !claimMode,
            webhookMode: webhookMode, webhookToggle: webhookToggle)
        let created = model.owners.first(where: { $0.server == server })?.objects?.first { !before.contains($0.id) }
        // A persisted uncertain attempt stays in the object list; do not offer
        // another submission of the same potentially successful mutation.
        if result || created != nil { finish(created.map { .owned(server: server, objectID: $0.id) }) }
    }
    private func finish(_ target: ObjectReference?) {
        completion?(target)
        dismiss()
    }
}

/// Public iOS telephony requires confirmation and does not expose call hangup.
/// Keep imported Android configuration intact without offering a fake switch.
private struct PhoneHangupLimitation: View {
    let hangupSeconds: Int
    var body: some View {
        Section {
            Text(ProductText.string("ios_call_confirmation_required"))
                .font(.footnote).foregroundStyle(Brand.secondaryInk)
            if hangupSeconds > 0 {
                Text(ProductText.string("ios_call_imported_hangup",hangupSeconds)).font(.footnote).foregroundStyle(Brand.secondaryInk)
            }
        } header: { Text(ProductText.string("hangup_title")) }
    }
}

struct OwnerObjectEditor: View {
    @EnvironmentObject private var model: AppModel
    let server: String
    let objectID: UUID
    var showDeleteOnLaunch = false
    var body: some View {
        Group {
            if let owner = model.owners.first(where: { $0.server == server }),
               let object = owner.objects?.first(where: { $0.id == objectID }),
               let draft = try? OwnerObjectEdit(object: object, masterKey: owner.masterKey) {
                OwnerObjectEditorForm(server: server, objectID: objectID, initialDraft: draft,
                    showDeleteOnLaunch: showDeleteOnLaunch)
            } else { Text("Объект недоступен").foregroundStyle(Brand.secondaryInk) }
        }
    }
}

private struct OwnerDeviceCredentialsPrompt: Identifiable {
    let id = UUID()
    let credentials: DeviceConfigurationCredentials
}

private struct OwnerObjectEditorForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    let objectID: UUID
    let showDeleteOnLaunch: Bool
    @State private var draft: OwnerObjectEdit
    @State private var targetServer: String
    @State private var confirmingMove = false
    @State private var automation = false
    @State private var serverModeWarning = false
    @State private var credentialsPrompt: OwnerDeviceCredentialsPrompt?
    @State private var noCredentials = false
    @State private var bindingCode: String?
    @State private var deleting = false
    init(server: String, objectID: UUID, initialDraft: OwnerObjectEdit, showDeleteOnLaunch: Bool) {
        self.server = server; self.objectID = objectID; self.showDeleteOnLaunch = showDeleteOnLaunch
        _targetServer = State(initialValue: server)
        var draft = initialDraft
        if draft.webhookSecret.isEmpty { draft.webhookSecret = PhoneWebhook.newSecret() }
        _draft = State(initialValue: draft)
    }
    private var object: OwnerObject? { model.owners.first { $0.server == server }?.objects?.first { $0.id == objectID } }
    private var move: OwnerBLEMove? { model.bleMove(server: server, objectID: objectID) }
    private var canSave: Bool {
        guard let object else { return false }
        return model.canManageGuestAccess && !model.ownerBusy && move == nil && object.available != false && object.pending == nil &&
            object.revision != nil && !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (object.kind != "call" || !draft.phone.isEmpty) &&
            (object.kind != "webhook" || !draft.webhookURL.isEmpty && !draft.webhookSecret.isEmpty)
    }
    var body: some View {
        Form {
            if let object {
                Section {
                    if object.kind != "ble", model.owners.filter({ !$0.registrationPending }).count > 1 {
                        Text(ProductText.string("object_server") + ": " + server).font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                    AppField(ProductText.string("add_object_name")) {
                        TextField(ProductText.string("add_object_name"), text: $draft.label)
                            .onChange(of: draft.label) { draft.label = String($0.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "").prefix(64)) }
                    }
                    if object.kind == "call" {
                        AppField(ProductText.string("add_object_phone")) {
                            TextField(ProductText.string("add_object_phone"), text: $draft.phone).keyboardType(.phonePad)
                        }
                    } else if object.kind == "webhook" {
                        WebhookConfigurationFields(url: $draft.webhookURL, secret: $draft.webhookSecret,
                            mode: $draft.webhookMode, toggles: $draft.webhookToggle, requestServerMode: { serverModeWarning = true })
                    }
                }.disabled(model.ownerBusy || object.pending != nil || object.available == false || move != nil)
                if object.kind == "ble" { bleFields }
                if object.kind == "call" { PhoneHangupLimitation(hangupSeconds: draft.local.hangupSeconds) }
                if object.kind == "device" { deviceFields }
                if object.kind != "ble" {
                    Section {
                        ObjectCameraFields(camera: $draft.local.camera)
                    }.disabled(model.ownerBusy || object.pending != nil || object.available == false)
                }
                if object.pending != nil || object.available == false || object.revision == nil {
                    recoveryFields(object)
                }
                if let message = model.ownerObjectMessages[objectID] {
                    Section { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                }
                if move == nil {
                    Section {
                        Button {
                            if object.kind == "ble", targetServer != server { confirmingMove = true }
                            else { Task { if await model.updateOwnerObject(server: server, objectID: objectID, draft: draft) { dismiss() } } }
                        } label: {
                            ActionButtonLabel(title: ProductText.string(object.kind == "ble" && targetServer != server ? "ble_move_button" : "btn_save"), busy: model.ownerBusy)
                        }.buttonStyle(PrimaryActionStyle()).actionListRow().disabled(!canSave)
                    }
                }
            }
        }
        .toolbar(.hidden,for:.navigationBar)
        .safeAreaInset(edge:.top,spacing:0) {
            HStack(spacing:12) {
                Text(ProductText.string(object?.kind == "ble" ? "ble_object_default" : "edit_object_title"))
                    .font(.title3.weight(.semibold)).frame(maxWidth:.infinity,alignment:.leading)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("owner-object-title")
                if object?.kind != "ble" {
                    Button { automation = true } label: { AutomationIcon() }
                        .buttonStyle(SquareIconActionStyle())
                        .accessibilityLabel(ProductText.string("owner_automation_desc")).accessibilityIdentifier("owner-object-automation")
                }
            }.padding(.horizontal,DesignMetrics.pageInset).padding(.vertical,12)
                .background(Color(uiColor:.systemGroupedBackground))
        }
        .sheet(isPresented: $automation) { AutomationEditor(destination: .object(.owned(server: server, objectID: objectID))) }
        .sheet(item: $credentialsPrompt) { prompt in
            DeviceCredentialsSheet(credentials: prompt.credentials, server: server)
        }
        .appMessageDialog("Entrixy",message:model.errorMessage ?? "",actionTitle:ProductText.string("btn_ok"),isPresented:Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }))
        .appMessageDialog(ProductText.string("edit_object_no_creds_title"),message:ProductText.string("edit_object_no_creds_text"),actionTitle:ProductText.string("btn_ok"),isPresented:$noCredentials)
        .task { if showDeleteOnLaunch { deleting = true } }
        .interactiveDismissDisabled(model.ownerBusy)
        .accessibilityHidden(serverModeWarning || deleting || confirmingMove)
        .overlay {
            if confirmingMove {
                AppConfirmationDialog(title:ProductText.string("ble_move_title",targetServer),message:ProductText.string("ble_move_hint"),actionTitle:ProductText.string("ble_move_button"),cancel:{ confirmingMove = false },confirm:{
                    confirmingMove = false
                    Task { if await model.moveBLEObject(server:server,objectID:objectID,to:targetServer) { dismiss() } }
                })
            } else if serverModeWarning {
                WebhookServerModeConfirmation(cancel: { serverModeWarning = false }, confirm: { draft.webhookMode = "server"; serverModeWarning = false })
            } else if deleting {
                AppConfirmationDialog(title: "Удалить объект?", message: "Гости потеряют доступ к этому объекту.",
                    actionTitle: "Удалить объект", destructive: true, cancel: { deleting = false }, confirm: {
                        deleting = false
                        Task { await model.deleteOwnerObject(server: server, objectID: objectID); if object == nil { dismiss() } }
                    })
            }
        }
    }
    @ViewBuilder private var bleFields: some View {
        let hosts = model.owners.filter { !$0.registrationPending }.map(\.server)
        if hosts.count > 1 {
            Section {
                ForEach(hosts, id: \.self) { host in
                    ObjectRadioChoice(title: host, selected: (move?.destination ?? targetServer) == host) { targetServer = host }
                }
                if targetServer != server || move != nil { Text(ProductText.string("ble_move_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk) }
            } header: { Text(ProductText.string("ble_server_label")) }
                .disabled(model.ownerBusy || move != nil)
        }
        if let move {
            Section { Text("Перенос ожидает подтверждения: " + move.destination).foregroundStyle(Brand.secondaryInk) }
            Section {
                Button { Task { if await model.moveBLEObject(server: server, objectID: objectID, to: move.destination) { dismiss() } } } label: {
                    ActionButtonLabel(title: "Проверить результат", busy: model.ownerBusy)
                }.buttonStyle(PrimaryActionStyle()).actionListRow().disabled(model.ownerBusy)
            }
        }
    }
    private var deviceFields: some View {
        Group {
            Section {
                Button {
                    do {
                        if let credentials = try model.ownerDeviceCredentials(server: server, objectID: objectID) {
                            credentialsPrompt = OwnerDeviceCredentialsPrompt(credentials: credentials)
                        } else { noCredentials = true }
                    } catch { model.errorMessage = "Не удалось прочитать сохранённые параметры устройства." }
                } label: { Label(ProductText.string("edit_object_share_device"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(SecondaryActionStyle()).actionListRow().accessibilityIdentifier("device-share-credentials")
            }
            Section {
                Button {
                    if bindingCode != nil { bindingCode = nil; return }
                    do { bindingCode = try model.ownerSocketBindingCode(server: server, objectID: objectID) }
                    catch { model.errorMessage = "Не удалось сохранить привязку к приложению. Новый код не создавался." }
                } label: { Label(ProductText.string("edit_object_bind_app"), systemImage: "lock") }
                    .buttonStyle(SecondaryActionStyle()).actionListRow()
                    .disabled(model.ownerBusy || object?.pending != nil || object?.available == false)
            }
            if let bindingCode {
                Section {
                    Text(ProductText.string("edit_object_bind_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                    Text(bindingCode).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                }
                Section {
                    Button { UIPasteboard.general.string = bindingCode } label: {
                        Label(ProductText.string("edit_object_bind_copy"), systemImage: "doc.on.doc")
                    }.buttonStyle(SecondaryActionStyle()).actionListRow()
                }
            }
        }
    }
    @ViewBuilder private func recoveryFields(_ object: OwnerObject) -> some View {
        Section {
            if object.available == false {
                Text("Объект недоступен. Обновите данные сервера, прежде чем изменять его.").foregroundStyle(Brand.secondaryInk)
            }
            if object.pending != nil {
                Text(object.sent ? "Результат запроса не подтверждён. Обновление проверит его без повторной отправки." : "Изменение ещё не применено.")
                    .foregroundStyle(Brand.secondaryInk)
            } else if object.revision == nil {
                Text("Для безопасного изменения сначала обновите данные. Сервер должен поддерживать проверку версии объекта.")
                    .font(.footnote).foregroundStyle(Brand.secondaryInk)
            }
        }
        Section {
            Button("Проверить результат") { Task { await model.refreshOwners() } }
                .buttonStyle(SecondaryActionStyle()).actionListRow().disabled(model.ownerBusy)
        }
        if model.canSaveOwnerObjectResult(objectID) {
            Section {
                Button("Сохранить результат") { Task { await model.retrySavingOwnerObjectResult(server: server, objectID: objectID) } }
                    .buttonStyle(PrimaryActionStyle()).actionListRow().disabled(model.ownerBusy)
            }
        } else if !object.sent && object.pending == .create && object.routing["device_id_ref"] != nil {
            Section {
                Button("Повторить создание объекта") { Task { await model.retryPreparedOwnerObject(server: server, objectID: objectID) } }
                    .buttonStyle(PrimaryActionStyle()).actionListRow().disabled(model.ownerBusy)
            }
        } else if object.pending != nil && !object.sent {
            Section {
                Button("Отменить изменение", role: .destructive) {
                    model.cancelOwnerObjectChange(server: server, objectID: objectID)
                    if let owner = model.owners.first(where: { $0.server == server }), let object = self.object,
                       let restored = try? OwnerObjectEdit(object: object, masterKey: owner.masterKey) { draft = restored }
                    if self.object == nil { dismiss() }
                }.buttonStyle(SecondaryActionStyle()).actionListRow().disabled(model.ownerBusy)
            }
        }
    }
}
