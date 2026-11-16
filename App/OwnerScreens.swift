import SwiftUI
import EntrixyCore

struct OwnerServersScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    var body: some View {
        List {
            Section {
                ForEach(model.owners) { owner in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(owner.server).font(.headline)
                        if owner.registrationPending {
                            Text(model.ownerMessages[owner.server] ?? "Регистрация была отправлена, но её результат не подтверждён. Повторная регистрация не выполняется.")
                                .font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            if model.canSaveOwnerAccess(owner.server) {
                                Button("Сохранить доступ") { Task { await model.retrySavingOwnerAccess(owner.server) } }.buttonStyle(PrimaryActionStyle())
                                    .disabled(model.ownerBusy)
                            }
                        } else {
                            NavigationLink("Настроить объекты") { OwnerObjectsScreen(server: owner.server) }
                            if let snapshot = model.ownerSnapshots[owner.server] {
                                Text("Объектов: \(snapshot.objectCount) · Выданных ключей: \(snapshot.guestKeyCount)")
                                    .font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            }
                            if let date = owner.lastSynced {
                                Text("Обновлено: \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(Brand.secondaryInk)
                            }
                            if let message = model.ownerMessages[owner.server] {
                                Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            }
                        }
                    }.padding(.vertical, 6)
                }
                Button { adding = true } label: { Label("Добавить сервер", systemImage: "plus") }
                    .disabled(!model.storageReady || model.ownerBusy)
            } header: { Text("Мои серверы") }
            footer: { Text("На каждом сервере сохраняется отдельный доступ владельца. Полученные от других людей ключи находятся в настройках на вкладке «Ключи».") }
        }
        .navigationTitle("Мои серверы").navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshOwners() }
        .task { await model.refreshOwners() }
        .sheet(isPresented: $adding) { AddOwnerServerScreen() }
    }
}

struct AddOwnerServerScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var server: String
    init(initialServer: String = "entrixy.com") { _server = State(initialValue: initialServer) }
    @State private var accessCode = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppField("Адрес сервера") {
                        TextField("Адрес сервера", text: $server)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    AppField("Код сервера, если нужен") {
                        SecureField("Код сервера, если нужен", text: $accessCode)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("Сервер Entrixy") }
                footer: { Text("Добавление создаст доступ владельца на этом сервере и сохранит его в защищённом хранилище iPhone.") }
                Section {
                    Button {
                        Task {
                            if await model.addOwner(server: server, accessCode: accessCode) { dismiss() }
                        }
                    } label: {
                        ActionButtonLabel(title: "Добавить сервер", busy: model.ownerBusy)
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .actionListRow()
                    .disabled(model.ownerBusy || !model.storageReady || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Добавить сервер").navigationBarTitleDisplayMode(.inline)
            .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }

            .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("Понятно") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }
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
                    Button { adding = true } label: { Label("Добавить объект", systemImage: "plus") }
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
    @State private var kind = "device"
    @State private var phone = ""
    @State private var url = ""
    @State private var secret = ""
    @State private var claimCode = ""
    @State private var pairing = false
    var embedded = false
    private var complete: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (kind == "ble" || (kind == "device" ? !claimCode.isEmpty : (kind == "call" ? !phone.isEmpty : !url.isEmpty && !secret.isEmpty)))
    }
    var body: some View {
        Group {
            if embedded { fields } else { NavigationStack { fields } }
        }
    }
    private var fields: some View {
            Form {
                Section {
                    AppField("Название") {
                        TextField("Название", text: $label)
                    }
                    Picker("Тип объекта", selection: $kind) {
                        Text("Контроллер Entrixy").tag("device")
                        Text("Телефонный звонок").tag("call")
                        Text("HTTPS-запрос с сервера").tag("webhook")
                        Text("Bluetooth").tag("ble")
                    }.accessibilityIdentifier("owner-object-kind")
                    if kind == "device" {
                        AppField("Код с корпуса контроллера") {
                            TextField("Код с корпуса контроллера", text: $claimCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        }
                    } else if kind == "call" {
                        AppField("Номер телефона") {
                            TextField("Номер телефона", text: $phone).keyboardType(.phonePad)
                        }
                        Text("iOS требует подтверждать телефонный звонок. Фоновый автодозвон недоступен.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    } else if kind == "ble" {
                        Text("Включите режим привязки на своём контроллере и держите iPhone рядом.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    } else {
                        AppField("Адрес HTTPS-запроса") {
                            TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        AppField("Секрет подписи запроса") {
                            SecureField("Секрет подписи запроса", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Text("Сервер будет отправлять подписанные запросы. Адрес и секрет передаются этому серверу для выполнения команды.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                } header: { Text(server) }
                Section {
                    Button {
                        if kind == "ble" { pairing = true; return }
                        Task {
                            let before = Set(model.owners.first(where: { $0.server == server })?.objects?.map(\.id) ?? [])
                            let result = await model.createOwnerObject(server: server, label: label, kind: kind, phone: phone, url: url, secret: secret, claimCode: claimCode)
                            let after = Set(model.owners.first(where: { $0.server == server })?.objects?.map(\.id) ?? [])
                            // A persisted uncertain attempt belongs in the object list, not a resubmittable form.
                            if result || !after.subtracting(before).isEmpty { dismiss() }
                        }
                    } label: {
                        ActionButtonLabel(title: kind == "ble" ? "Продолжить привязку" : "Добавить объект", busy: model.ownerBusy)
                    }.buttonStyle(PrimaryActionStyle()).actionListRow()
                        .disabled(!complete || model.ownerBusy)
                }
            }
            .navigationTitle("Добавить объект").navigationBarTitleDisplayMode(.inline)
            .task {
                #if DEBUG && targetEnvironment(simulator)
                if StageTwoCapture.current == .addObject { kind = "ble"; label = "Новый BLE-объект" }
                #endif
            }
            .navigationDestination(isPresented: $pairing) {
                BLEPairingScreen(server: server, initialLabel: label)
                    .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }
            }
            .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }

            .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("Понятно") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}

struct OwnerObjectEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    let objectID: UUID
    @State private var label = ""
    @State private var deleting = false
    @State private var preset: Int?
    @State private var confirmation = false
    @State private var authentication = "none"
    @State private var originalPolicy: Data?
    var showDeleteOnLaunch = false
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    private var object: OwnerObject? { owner?.objects?.first { $0.id == objectID } }
    var body: some View {
        Form {
            if let object {
                Section {
                    AppField("Название") {
                        TextField("Название", text: $label).disabled(object.pending != nil || object.available == false)
                    }
                    if object.available == false { Text("Объект недоступен. Обновите данные сервера, прежде чем изменять его.").foregroundStyle(Brand.secondaryInk) }
                    if let message = model.ownerObjectMessages[objectID] { Text(message).foregroundStyle(Brand.secondaryInk) }
                    if object.pending != nil {
                        Text(object.sent ? "Результат запроса не подтверждён. Обновление проверит его без повторной отправки." : "Изменение ещё не применено.").foregroundStyle(Brand.secondaryInk)
                        Button("Проверить результат") { Task { await model.refreshOwners() } }.buttonStyle(SecondaryActionStyle()).disabled(model.ownerBusy)
                        if model.canSaveOwnerObjectResult(objectID) {
                            Button("Сохранить результат") { Task { await model.retrySavingOwnerObjectResult(server: server, objectID: objectID) } }.buttonStyle(PrimaryActionStyle()).disabled(model.ownerBusy)
                        } else if !object.sent && object.pending == .create && object.routing["device_id_ref"] != nil {
                            Button("Повторить создание объекта") { Task { await model.retryPreparedOwnerObject(server: server, objectID: objectID) } }.buttonStyle(PrimaryActionStyle()).disabled(model.ownerBusy)
                        } else if !object.sent {
                            Button("Отменить изменение", role: .destructive) {
                                model.cancelOwnerObjectChange(server: server, objectID: objectID)
                                if self.object == nil { dismiss() }
                            }.buttonStyle(SecondaryActionStyle()).disabled(model.ownerBusy)
                        }
                    } else if object.revision == nil {
                        Text("Для безопасного изменения сначала обновите данные. Сервер должен поддерживать проверку версии объекта.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                }
                Section("Значок объекта") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 12) {
                        ForEach(0..<8) { index in
                            Button { preset = index } label: {
                                Image("object-\(index + 1)").resizable().scaledToFit().frame(width: 48, height: 48)
                                    .padding(4).background(preset == index ? Brand.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(preset == index ? Brand.ink : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).accessibilityLabel("Значок \(index + 1)")
                                .accessibilityAddTraits(preset == index ? .isSelected : [])
                        }
                    }.disabled(object.pending != nil || object.available == false)
                }
                Section {
                    Toggle("Подтверждать нажатие", isOn: $confirmation)
                    Picker("Подтверждение личности", selection: $authentication) {
                        Text("Не требуется").tag("none")
                        Text("PIN-код Entrixy").tag("pin")
                        Text("Биометрия").tag("biometric")
                        Text("PIN-код или биометрия").tag("either")
                    }
                    Button("Сохранить защиту") {
                        if model.saveOwnerActionPolicy(server: server, objectID: objectID, expected: originalPolicy,
                            confirmation: confirmation, authentication: authentication) { originalPolicy = self.object?.localPolicy }
                    }.buttonStyle(SecondaryActionStyle())
                } header: { Text("Моё ручное управление") } footer: {
                    Text("Эти правила действуют на этом iPhone. Условия выданных гостям ключей настраиваются отдельно.")
                }.disabled(model.ownerBusy || object.pending != nil || object.available == false)
                Section {
                    Button("Сохранить изменения") {
                        Task { if await model.renameOwnerObject(server: server, objectID: objectID, label: label, preset: preset) { dismiss() } }
                    }.buttonStyle(PrimaryActionStyle()).disabled(model.ownerBusy || object.available == false || object.pending != nil || object.revision == nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let did = object.bleDeviceID {
                        NavigationLink("Bluetooth-доступ гостей") { BLEPermissionsScreen(server: server, deviceID: did) }
                    }
                    Button("Удалить объект", role: .destructive) { deleting = true }.buttonStyle(SecondaryActionStyle()).disabled(model.ownerBusy || object.available == false || object.pending != nil)
                }
            }
        }
        .navigationTitle("Настройка объекта").navigationBarTitleDisplayMode(.inline)
        .task {
            if let owner, let object {
                let metadata = try? object.metadata(masterKey: owner.masterKey)
                label = metadata?["label"] as? String ?? ""
                if let value = metadata?["avatar_type"] as? String, value.hasPrefix("preset:") { preset = Int(value.dropFirst(7)) }
                originalPolicy = object.localPolicy
                if let policy = try? OwnerManualPolicy(object.localPolicy) {
                    confirmation = policy.confirmation; authentication = policy.authentication ?? "none"
                }
            }
            if showDeleteOnLaunch { deleting = true }
        }
        .overlay {
            if deleting {
                AppConfirmationDialog(title: "Удалить объект?", message: "Гости потеряют доступ к этому объекту.",
                    actionTitle: "Удалить объект", destructive: true, cancel: { deleting = false }, confirm: {
                        deleting = false
                        Task { await model.deleteOwnerObject(server: server, objectID: objectID); if object == nil { dismiss() } }
                    })
            }
        }
    }
}
