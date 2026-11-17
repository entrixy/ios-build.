import SwiftUI
import CoreImage.CIFilterBuiltins
import EntrixyCore

struct OwnerGuestsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    var body: some View {
        List {
            if model.navigationState.canDelegate || !model.passedAccess.isEmpty {
                Section { NavigationLink("Передать полученный доступ") { PassedAccessScreen() } }
            }
            if model.owners.filter({ !$0.registrationPending }).isEmpty && !model.navigationState.canDelegate {
                Section {
                    Text("Добавьте свой сервер и объекты в настройках, чтобы выдавать ключи гостям.").foregroundStyle(Brand.secondaryInk)
                    NavigationLink("Мои серверы") { OwnerServersScreen() }
                }
            }
            ForEach(model.owners.filter { !$0.registrationPending }) { owner in
                Section(owner.server) {
                    ForEach(owner.issuedKeys ?? []) { key in
                        NavigationLink { OwnerKeyScreen(server: owner.server, keyID: key.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(key.label).font(.headline)
                                Text(ownerKeyStatus(key)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            }.padding(.vertical, 5)
                        }
                    }
                    ForEach(owner.delegatedKeys ?? []) { key in
                        NavigationLink { OwnerDelegatedKeyScreen(server: owner.server, keyID: key.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(key.label).font(.headline)
                                Text(ownerDelegatedStatus(key)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            }.padding(.vertical, 5)
                        }
                    }
                    if (model.unverifiedOwnerDelegations[owner.server] ?? 0) > 0 {
                        Text("Некоторые передачи ещё не подтверждены: нет проверенного поручительства или доступной цепочки владельца.").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    }
                    if !(owner.androidKeys ?? []).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Сохранённые ключи Android: \(owner.androidKeys?.count ?? 0)").font(.headline)
                            Text("Секреты сохранены. Для восстановления нужно подтвердить связку и правила передачи; новые ключи автоматически не создаются.").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            Button("Проверить данные сервера") { Task { await model.refreshOwners() } }.buttonStyle(SecondaryActionStyle()).disabled(model.ownerBusy)
                        }.padding(.vertical, 5)
                    }
                    if (owner.issuedKeys ?? []).isEmpty && (owner.delegatedKeys ?? []).isEmpty && (owner.androidKeys ?? []).isEmpty { Text("Выданных ключей пока нет").foregroundStyle(Brand.secondaryInk) }
                }
            }
        }
        .navigationTitle("Гости")
        .toolbar { if model.owners.contains(where: { !$0.registrationPending }) { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus").accessibilityLabel("Выдать ключ") }.disabled(model.ownerBusy) } } }
        .refreshable { await model.refreshOwners() }
        .sheet(isPresented: $adding) { IssueOwnerKeyScreen() }
    }
}

func ownerKeyStatus(_ key: OwnerIssuedKey) -> String {
    if key.pending != nil { return key.sent ? "Ожидает подтверждения сервера" : "Запрос ещё не применён" }
    switch key.state {
    case .active: return "Доступ действует"
    case .paused: return "Доступ приостановлен"
    case .revoked: return "Ключ отозван"
    case .draft: return "Подготовка ключа"
    case .unavailable: return "Ключ недоступен на сервере"
    case .restricted: return "Нужна обработка запроса владельцем"
    }
}

private enum GuestObjectTask: Identifiable {
    case automation(ObjectReference), invocation(ObjectReference), access(ObjectReference)
    var target: ObjectReference { switch self { case .automation(let t), .invocation(let t), .access(let t): return t } }
    var id: String { switch self { case .automation: return "auto:" + target.id; case .invocation: return "call:" + target.id; case .access: return "access:" + target.id } }
}

struct IssueOwnerKeyScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editingKeyID: UUID?
    @StateObject private var draft = GuestKeyDraft()
    @State private var server: String
    @State private var loaded = false
    @State private var label = ""
    @State private var welcome = ""
    @State private var task: GuestObjectTask?
    init(serverPreset: String? = nil, editingKeyID: UUID? = nil, editAccessOnLaunch: Bool = false) {
        self.editingKeyID = editingKeyID; _server = State(initialValue: serverPreset ?? "")
    }
    private var owner: OwnerAccount? { model.owners.first { $0.server == server && !$0.registrationPending } }
    private func host(_ entry: CatalogObject) -> String {
        if case let .owned(account, _) = entry { return account.server }; return ""
    }
    private var rows: [CatalogObject] {
        let values = model.catalogObjects().filter {
            guard case let .owned(account, _) = $0, !account.registrationPending else { return false }
            return editingKeyID == nil || account.server == server
        }
        var hosts: [String] = []
        for entry in values where !hosts.contains(host(entry)) { hosts.append(host(entry)) }
        return hosts.flatMap { hostname in values.filter { host($0) == hostname } }
    }
    private func startsGroup(_ entry: CatalogObject) -> Bool {
        Set(rows.map(host)).count > 1 && rows.first(where: { host($0) == host(entry) })?.id == entry.id
    }
    private func eligible(_ object: OwnerObject) -> Bool {
        object.numberID != nil && object.pending == nil && object.available != false && (object.kind != "device" || object.wrappedSocketSecret != nil)
    }
    private func access(_ number: Int) -> KeyObjectAccess { draft.access[number] ?? (try! KeyObjectAccess()) }
    private func toggle(_ account: OwnerAccount, _ object: OwnerObject) {
        guard let number = object.numberID, eligible(object) else { return }
        if draft.selected.isEmpty, editingKeyID == nil, server != account.server {
            draft.access = [:]; draft.templates = [:]; draft.streams = [:]; draft.lifetimes = [:]; draft.calls = [:]
            server = account.server
        }
        guard server == account.server else { return }
        if draft.selected.contains(number) { draft.selected.remove(number) }
        else { draft.selected.insert(number) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppField(ProductText.string("guests_default_name")) {
                        TextField(ProductText.string("guests_default_name"), text: $label)
                            .onChange(of: label) { label = String($0.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "").prefix(64)) }
                    }
                    AppField(ProductText.string("guests_welcome_label")) {
                        TextField(ProductText.string("guests_welcome_hint"), text: $welcome, axis: .vertical)
                            .onChange(of: welcome) { welcome = String($0.prefix(500)) }
                    }
                }
                Section {
                    ForEach(rows) { entry in objectRow(entry) }
                    if rows.isEmpty { Text("Сначала добавьте объект в настройках").foregroundStyle(Brand.secondaryInk) }
                } header: { Text(ProductText.string("guests_objects_allowed")) }
                Section {
                    Button { Task { await save() } } label: {
                        ActionButtonLabel(title: editingKeyID == nil ? "Выдать ключ" : ProductText.string("btn_save"), busy: model.ownerBusy)
                    }.buttonStyle(PrimaryActionStyle()).actionListRow().disabled(model.ownerBusy || draft.selected.isEmpty || (editingKeyID != nil && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }.navigationTitle(editingKeyID == nil ? "Выдать ключ" : ProductText.string("guests_access_title"))
                .navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }
                .task {
                    guard !loaded else { return }; loaded = true
                    if let editingKeyID, let owner, let key = owner.issuedKeys?.first(where: { $0.id == editingKeyID }) {
                        model.beginEditingGuestKey(editingKeyID)
                        do {
                            try draft.load(owner: owner, key: key)
                            label = key.label; welcome = try key.bundle(masterKey: owner.masterKey)["welcome"] as? String ?? ""
                        } catch { model.errorMessage = "Не удалось прочитать настройки ключа." }
                    }
                }
                .onDisappear { if task == nil, let editingKeyID { model.endEditingGuestKey(editingKeyID) } }
                .sheet(item: $task, onDismiss: { if let owner { draft.syncSavedSettings(owner: owner) } }) { task in nested(task) }
                .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button(ProductText.string("btn_ok")) { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
    }
    @ViewBuilder private func objectRow(_ entry: CatalogObject) -> some View {
        if case let .owned(account, object) = entry, let number = object.numberID {
            let selected = account.server == server && draft.selected.contains(number)
            let locked = !draft.selected.isEmpty && server != account.server
            VStack(alignment: .leading, spacing: 8) {
                if startsGroup(entry) {
                    Text(account.server).font(.footnote).foregroundStyle(Brand.secondaryInk)
                }
                HStack(spacing: 6) {
                    Button { toggle(account, object) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                            Text(model.objectLabel(entry)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.foregroundStyle(Brand.ink).frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(locked || !eligible(object) || model.ownerBusy)
                        .accessibilityIdentifier("guest-object-" + entry.target.id)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    if selected {
                        if ["call", "webhook", "ble"].contains(object.kind) {
                            objectButton("hand.tap", label: ProductText.string("guests_call_cfg_desc")) { task = .invocation(entry.target) }
                        }
                        objectButton("arrow.triangle.2.circlepath", label: ProductText.string("guests_automation_desc")) { task = .automation(entry.target) }
                        objectButton("person.badge.key", label: ProductText.string("obj_access_desc")) { task = .access(entry.target) }
                    }
                }
                if selected, object.kind != "ble", let camera = object.localConfiguration?.camera, camera.enabled, !camera.url.isEmpty {
                    Toggle(ProductText.string("guests_grant_video"), isOn: Binding(get: { draft.streams[number] ?? true }, set: { draft.streams[number] = $0 }))
                        .font(.subheadline).padding(.leading, 30)
                }
            }
        }
    }
    private func objectButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(maxWidth: .infinity) }
            .buttonStyle(SecondaryActionStyle()).frame(width: 48).accessibilityLabel(label)
    }
    @ViewBuilder private func nested(_ task: GuestObjectTask) -> some View {
        if case let .owned(host, id) = task.target, let account = model.owners.first(where: { $0.server == host }),
           let object = account.objects?.first(where: { $0.id == id }), let number = object.numberID {
            let saved = editingKeyID.flatMap { keyID in account.issuedKeys?.first(where: { $0.id == keyID && $0.numberIDs.contains(number) }) }
            switch task {
            case .automation:
                if let saved { AutomationEditor(destination: .issued(server: host, keyID: saved.id, objectID: id)) }
                else { DraftGuestAutomationEditor(draft: draft, server: host, objectID: id) }
            case .access:
                GuestObjectAccessEditor(title: model.objectLabel(.owned(account, object)), value: Binding(get: { access(number) }, set: { draft.access[number] = $0 }))
            case .invocation:
                if object.kind == "ble" {
                    GuestBLELifetimeEditor(label: model.objectLabel(.owned(account, object)), seconds: Binding(get: {
                        if let keyID = saved?.id { return model.owners.first(where: { $0.server == host })?.issuedKeys?.first(where: { $0.id == keyID })?.bleTokenLifetimes?[String(number)] ?? BLETokenLifetime.defaultValue }
                        return draft.lifetimes[number] ?? BLETokenLifetime.defaultValue
                    }, set: { seconds in
                        if let saved { if model.saveIssuedLifetime(server: host, keyID: saved.id, objectID: id, seconds: seconds) { draft.lifetimes[number] = seconds } }
                        else { draft.lifetimes[number] = seconds }
                    }))
                } else {
                    GuestInvocationEditor(server: host, objectID: id, preference: Binding(get: {
                        if let keyID = saved?.id { return model.owners.first(where: { $0.server == host })?.issuedKeys?.first(where: { $0.id == keyID })?.callPreferences?[String(number)] ?? OwnerCallPreference() }
                        return draft.calls[number] ?? OwnerCallPreference()
                    }, set: { preference in
                        if let saved { if model.saveIssuedCallPreference(server: host, keyID: saved.id, objectID: id, preference: preference) { draft.calls[number] = preference } }
                        else { draft.calls[number] = preference }
                    }))
                }
            }
        }
    }
    private func save() async {
        guard let owner else { return }
        do {
            draft.syncSavedSettings(owner: owner)
            let configuration = try draft.configuration(owner: owner)
            let rights = Dictionary(uniqueKeysWithValues: draft.selected.map { ($0, access($0)) })
            let before = Set(owner.issuedKeys?.map(\.id) ?? [])
            let previousCipher = owner.issuedKeys?.first(where: { $0.id == editingKeyID })?.bundleCipher
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ProductText.string("guests_default_name") : label
            let result: Bool
            if let editingKeyID {
                result = await model.editOwnerKey(server: server, keyID: editingKeyID, label: name, numberIDs: Array(draft.selected), welcome: welcome, confirmation: nil, access: rights, settings: configuration)
            } else {
                result = await model.createOwnerKey(server: server, label: name, numberIDs: Array(draft.selected), welcome: welcome, nativeOnly: false, confirmation: false, access: rights, settings: configuration)
            }
            let after = model.owners.first { $0.server == server }?.issuedKeys ?? []
            if result || after.contains(where: { !before.contains($0.id) || ($0.id == editingKeyID && $0.bundleCipher != previousCipher && $0.pending != nil) }) {
                if let editingKeyID { model.endEditingGuestKey(editingKeyID) }
                dismiss()
            }
        } catch { model.errorMessage = "Не удалось сохранить настройки доступа." }
    }
}

struct OwnerKeyScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    let keyID: UUID
    @State private var revoking = false
    @State private var renewingBLE = false
    @State private var composing = false
    @State private var editing = false
    @State private var reviewingRestoredAccess = false
    var showRevokeOnLaunch = false
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    private var key: OwnerIssuedKey? { owner?.issuedKeys?.first { $0.id == keyID } }
    private var link: URL? { guard let owner, let key else { return nil }; return try? key.link(server: server, masterKey: owner.masterKey) }
    var body: some View {
        List {
            if let key {
                Section {
                    Text(key.label).font(.title3.bold())
                    Text(ownerKeyStatus(key)).foregroundStyle(Brand.secondaryInk)
                    KeyValueRow(title: "Сервер", value: server)
                    KeyValueRow(title: "Объектов", value: String((key.effectiveNumberIDs ?? key.numberIDs).count))
                    if let message = model.ownerKeyMessages[keyID] { Text(message).foregroundStyle(Brand.secondaryInk) }
                    if let owner, let bundle = try? key.bundle(masterKey: owner.masterKey), let rows = bundle["ble"] as? [[String: Any]], !rows.isEmpty {
                        ForEach(rows.compactMap { try? BLEGuestGrant(row: $0) }, id: \.objectID) { grant in
                            KeyValueRow(title: "Bluetooth-пропуск", value: Date(timeIntervalSince1970: Double(grant.validUntil)).formatted(date: .abbreviated, time: .shortened))
                        }
                        Text("Bluetooth-отзыв нужно доставить контроллеру. До этого офлайн-пропуск может действовать до указанного срока.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                }
                if let link {
                    Section {
                        InviteQRCode(text: link.absoluteString).frame(maxWidth: .infinity).padding(.vertical, 12)
                        ShareLink(item: link) { Label("Передать ссылку гостю", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryActionStyle())
                        Text(link.absoluteString).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                    } footer: { Text("Ключ предназначен одному получателю. При первом добавлении сервер привяжет его к устройству гостя.") }
                }
                Section {
                    if key.accessNeedsReview == true {
                        Text("Ключ восстановлен. Проверьте правила передачи доступа перед новой выдачей по цепочке.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                        Button("Проверить правила передачи") { reviewingRestoredAccess = true; editing = true }.buttonStyle(SecondaryActionStyle())
                            .disabled(key.pending != nil)
                    }
                    if key.pending != nil {
                        Button("Проверить результат") { Task { await model.refreshOwners() } }.buttonStyle(SecondaryActionStyle())
                        if model.canSaveOwnerKeyResult(keyID) {
                            Button("Сохранить результат") { Task { await model.retrySavingOwnerKeyResult(server: server, keyID: keyID) } }.buttonStyle(PrimaryActionStyle())
                        } else if !key.sent {
                            Button("Повторить запрос") { Task { await model.retryPreparedOwnerKey(server: server, keyID: keyID) } }.buttonStyle(PrimaryActionStyle())
                            if key.keyID == nil {
                                Button("Отменить выдачу", role: .destructive) { model.discardUnsentOwnerKey(server: server, keyID: keyID); if self.key == nil { dismiss() } }.buttonStyle(SecondaryActionStyle())
                            }
                        }
                    } else if key.state == .active || key.state == .paused {
                        Button(key.state == .paused ? "Возобновить доступ" : "Приостановить доступ") { Task { await model.setOwnerKeyMode(server: server, keyID: keyID, paused: key.state != .paused) } }.buttonStyle(SecondaryActionStyle())
                    }
                    if key.pending == nil, key.state == .active, let owner,
                       let bundle = try? key.bundle(masterKey: owner.masterKey), let rows = bundle["ble"] as? [[String: Any]], !rows.isEmpty {
                        Button("Продлить Bluetooth-пропуска на 24 часа") { renewingBLE = true }.buttonStyle(SecondaryActionStyle())
                    }
                    if key.pending == nil && [.active, .paused, .restricted].contains(key.state) {
                        Button("Написать сообщение") { composing = true }.buttonStyle(SecondaryActionStyle())
                    }
                    if key.keyID != nil && key.state != .revoked { Button("Отозвать ключ", role: .destructive) { revoking = true }.buttonStyle(SecondaryActionStyle()) }
                }.disabled(model.ownerBusy)
            }
        }
        .navigationTitle("Выданный ключ").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $composing) { ComposeMessageScreen(manager: model.messages, target: .owner(server: server, keyID: keyID)) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let key, key.pending == nil, key.state == .active || key.state == .paused {
                    Button("Изменить") { reviewingRestoredAccess = false; editing = true }.disabled(model.ownerBusy)
                }
            }
        }
        .sheet(isPresented: $editing) { IssueOwnerKeyScreen(serverPreset: server, editingKeyID: keyID, editAccessOnLaunch: reviewingRestoredAccess) }
        .task { if showRevokeOnLaunch { revoking = true } }
        .confirmationDialog("Продлить Bluetooth-пропуска на 24 часа?", isPresented: $renewingBLE, titleVisibility: .visible) {
            Button("Продлить") { Task { await model.renewOwnerBLEKey(server: server, keyID: keyID) } }
        }
        .confirmationDialog("Отозвать ключ? Гость и получатели переданного им доступа потеряют доступ.", isPresented: $revoking, titleVisibility: .visible) {
            Button("Отозвать ключ", role: .destructive) { Task { await model.revokeOwnerKey(server: server, keyID: keyID) } }
        }
    }
}

struct InviteQRCode: View {
    let text: String
    var body: some View {
        if let image {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("QR-код гостевого ключа")
        }
    }
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }
}
