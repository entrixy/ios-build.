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

struct IssueOwnerKeyScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editingKeyID: UUID?
    init(serverPreset: String? = nil, editingKeyID: UUID? = nil, editAccessOnLaunch: Bool = false) {
        self.editingKeyID = editingKeyID
        _changeAccess = State(initialValue: editAccessOnLaunch)
        _server = State(initialValue: serverPreset ?? "")
    }
    @State private var server = ""
    @State private var loaded = false
    @State private var changeConfirmation = false
    @State private var changeAccess = false
    @State private var access: [Int: KeyObjectAccess] = [:]
    @State private var label = ""
    @State private var welcome = ""
    @State private var confirmation = true
    @State private var selected = Set<Int>()
    private var owners: [OwnerAccount] { model.owners.filter { !$0.registrationPending } }
    private var owner: OwnerAccount? { owners.first { $0.server == server } }
    private func eligible(_ object: OwnerObject) -> Bool { object.numberID != nil && object.pending == nil && object.available != false && (object.kind != "device" || object.wrappedSocketSecret != nil) }
    private func settings(_ id: Int) -> KeyObjectAccess { access[id] ?? (try! KeyObjectAccess()) }
    private var requestedAccess: [Int: KeyObjectAccess]? {
        if editingKeyID != nil && !changeAccess { return nil }
        return Dictionary(uniqueKeysWithValues: selected.map { ($0, settings($0)) })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Сервер", selection: $server) { ForEach(owners) { Text($0.server).tag($0.server) } }.disabled(editingKeyID != nil || model.ownerBusy)
                    AppField("Имя гостя") {
                        TextField("Имя гостя", text: $label)
                    }
                    AppField("Приветствие гостю") {
                        TextField("Приветствие гостю", text: $welcome, axis: .vertical)
                    }
                    if editingKeyID != nil { Toggle("Изменить подтверждение открытия", isOn: $changeConfirmation) }
                    if editingKeyID == nil || changeConfirmation { Toggle("Подтверждать нажатие перед открытием", isOn: $confirmation) }
                }
                Section("Объекты гостя") {
                    ForEach(owner?.objects ?? []) { object in
                        if let id = object.numberID {
                            Button {
                                if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text((try? object.metadata(masterKey: owner!.masterKey)["label"] as? String) ?? "Название недоступно")
                                        if !eligible(object) { Text(object.kind == "device" && object.wrappedSocketSecret == nil ? "Сначала нужна защищённая настройка контроллера" : "Объект ожидает подтверждения").font(.caption).foregroundStyle(Brand.secondaryInk) }
                                    }
                                    Spacer()
                                    Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                                }.foregroundStyle(Brand.ink)
                            }.disabled(!eligible(object) || model.ownerBusy)
                        }
                    }
                    if (owner?.objects ?? []).isEmpty { Text("Сначала добавьте объект в настройках").foregroundStyle(Brand.secondaryInk) }
                }
                Section {
                    if editingKeyID != nil { Toggle("Изменить права передачи дальше", isOn: $changeAccess) }
                    if editingKeyID == nil || changeAccess {
                        ForEach(selected.sorted(), id: \.self) { id in
                            VStack(alignment: .leading, spacing: 12) {
                                Text((owner?.objects?.first(where: { $0.numberID == id })).flatMap { try? $0.metadata(masterKey: owner!.masterKey)["label"] as? String } ?? "Объект \(id)").font(.headline)
                                Stepper("Уровней передачи: \(settings(id).depth)", value: Binding(get: { settings(id).depth }, set: { access[id] = try? KeyObjectAccess(depth: $0, pool: settings(id).pool) }), in: 0...5)
                                if settings(id).depth > 0 {
                                    Stepper("Ключей ниже по цепочке: \(settings(id).pool)", value: Binding(get: { settings(id).pool }, set: { access[id] = try? KeyObjectAccess(depth: settings(id).depth, pool: $0) }), in: 1...50)
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                } header: { Text("Передача доступа") }
                footer: { Text("Ноль уровней запрещает передачу. Лимит ключей действует на всю цепочку ниже гостя для каждого объекта. Уменьшение прав может отозвать доступ у следующих получателей.") }
                Section {
                    Button {
                        Task {
                            let before = Set(owner?.issuedKeys?.map(\.id) ?? [])
                            let result: Bool
                            if let editingKeyID {
                                result = await model.editOwnerKey(server: server, keyID: editingKeyID, label: label, numberIDs: Array(selected), welcome: welcome, confirmation: changeConfirmation ? confirmation : nil, access: requestedAccess)
                            } else {
                                result = await model.createOwnerKey(server: server, label: label, numberIDs: Array(selected), welcome: welcome, nativeOnly: false, confirmation: confirmation, access: requestedAccess)
                            }
                            let after = Set(owner?.issuedKeys?.map(\.id) ?? [])
                            let pendingEdit = editingKeyID.flatMap { id in owner?.issuedKeys?.first(where: { $0.id == id })?.pending } != nil
                            if result || pendingEdit || !after.subtracting(before).isEmpty { dismiss() }
                        }
                    } label: { ActionButtonLabel(title: editingKeyID == nil ? "Выдать ключ" : "Сохранить изменения", busy: model.ownerBusy) }
                        .buttonStyle(PrimaryActionStyle()).actionListRow()
                        .disabled(model.ownerBusy || selected.isEmpty || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: { Text("Ссылка даст выбранному гостю доступ только к отмеченным объектам. Передавайте её лично получателю.") }
            }
            .navigationTitle(editingKeyID == nil ? "Выдать ключ" : "Изменить ключ").navigationBarTitleDisplayMode(.inline)
            .task {
                guard !loaded else { return }; loaded = true
                if server.isEmpty { server = owners.first?.server ?? "" }
                if let editingKeyID, let owner, let key = owner.issuedKeys?.first(where: { $0.id == editingKeyID }) {
                    label = key.label
                    selected = Set(key.effectiveNumberIDs ?? key.numberIDs)
                    access = Dictionary(uniqueKeysWithValues: (key.access ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
                    welcome = (try? key.bundle(masterKey: owner.masterKey)["welcome"] as? String) ?? ""
                }
            }
            .onChange(of: server) { _ in selected = []; access = [:] }
            .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }

            .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("Понятно") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        }
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
