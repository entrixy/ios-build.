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
                                Button("Сохранить доступ") { Task { await model.retrySavingOwnerAccess(owner.server) } }
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
            footer: { Text("На каждом сервере сохраняется отдельный доступ владельца. Полученные от других людей ключи находятся в разделе «Полученные ключи».") }
        }
        .navigationTitle("Мои серверы")
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
                    TextField("Адрес сервера", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Код сервера, если нужен", text: $accessCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Сервер Entrixy") }
                footer: { Text("Добавление создаст доступ владельца на этом сервере и сохранит его в защищённом хранилище iPhone.") }
                Section {
                    Button {
                        Task {
                            if await model.addOwner(server: server, accessCode: accessCode) { dismiss() }
                        }
                    } label: {
                        if model.ownerBusy { ProgressView().tint(Brand.secondaryInk) }
                        else { Text("Добавить сервер") }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .disabled(model.ownerBusy || !model.storageReady || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Добавить сервер").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(model.ownerBusy) } }
            .interactiveDismissDisabled(model.ownerBusy)
            .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("Понятно") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }
}

struct OwnerObjectsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    let server: String
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    var body: some View {
        List {
            if let owner {
                Section {
                    ForEach(owner.objects ?? []) { object in
                        NavigationLink { OwnerObjectEditor(server: server, objectID: object.id) } label: {
                            HStack(spacing: 14) {
                                Image("object-3").resizable().scaledToFit().frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text((try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Название недоступно").font(.headline)
                                    if object.pending != nil {
                                        Text(object.sent ? "Ожидает подтверждения сервера" : "Изменение не применено")
                                            .font(.subheadline).foregroundStyle(Brand.secondaryInk)
                                    }
                                    if let message = model.ownerObjectMessages[object.id] {
                                        Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                                    }
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                    if (owner.objects ?? []).isEmpty { Text("Пока нет добавленных объектов").foregroundStyle(Brand.secondaryInk) }
                    NavigationLink { BLEPairingScreen(server: server) } label: {
                        Label("Привязать Bluetooth-контроллер", systemImage: "antenna.radiowaves.left.and.right")
                    }.disabled(model.ownerBusy || owner.registrationPending)
                    Button { adding = true } label: { Label("Добавить объект", systemImage: "plus") }
                        .disabled(model.ownerBusy || owner.registrationPending)
                } header: { Text(server) }
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
        .navigationTitle("Мои объекты")
        .refreshable { await model.refreshOwners() }
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
    private var complete: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (kind == "device" ? !claimCode.isEmpty : (kind == "call" ? !phone.isEmpty : !url.isEmpty && !secret.isEmpty))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $label)
                    Picker("Тип объекта", selection: $kind) {
                        Text("Контроллер Entrixy").tag("device")
                        Text("Телефонный звонок").tag("call")
                        Text("HTTPS-запрос с сервера").tag("webhook")
                    }
                    if kind == "device" {
                        TextField("Код с корпуса контроллера", text: $claimCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    } else if kind == "call" {
                        TextField("Номер телефона", text: $phone).keyboardType(.phonePad)
                        Text("iOS требует подтверждать телефонный звонок. Фоновый автодозвон недоступен.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    } else {
                        TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Секрет подписи запроса", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Сервер будет отправлять подписанные запросы. Адрес и секрет передаются этому серверу для выполнения команды.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                } header: { Text(server) }
                Section {
                    Button {
                        Task {
                            let before = Set(model.owners.first(where: { $0.server == server })?.objects?.map(\.id) ?? [])
                            let result = await model.createOwnerObject(server: server, label: label, kind: kind, phone: phone, url: url, secret: secret, claimCode: claimCode)
                            let after = Set(model.owners.first(where: { $0.server == server })?.objects?.map(\.id) ?? [])
                            // A persisted uncertain attempt belongs in the object list, not a resubmittable form.
                            if result || !after.subtracting(before).isEmpty { dismiss() }
                        }
                    } label: {
                        if model.ownerBusy { ProgressView().tint(Brand.secondaryInk) }
                        else { Text("Добавить объект") }
                    }.buttonStyle(PrimaryActionStyle()).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        .disabled(!complete || model.ownerBusy)
                }
            }
            .navigationTitle("Добавить объект").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(model.ownerBusy) } }
            .interactiveDismissDisabled(model.ownerBusy)
            .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("Понятно") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }
}

struct OwnerObjectEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    let objectID: UUID
    @State private var label = ""
    @State private var deleting = false
    var showDeleteOnLaunch = false
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    private var object: OwnerObject? { owner?.objects?.first { $0.id == objectID } }
    var body: some View {
        Form {
            if let object {
                Section {
                    TextField("Название", text: $label).disabled(object.pending != nil || object.available == false)
                    if object.available == false { Text("Объект недоступен. Обновите данные сервера, прежде чем изменять его.").foregroundStyle(Brand.secondaryInk) }
                    if let message = model.ownerObjectMessages[objectID] { Text(message).foregroundStyle(Brand.secondaryInk) }
                    if object.pending != nil {
                        Text(object.sent ? "Результат запроса не подтверждён. Обновление проверит его без повторной отправки." : "Изменение ещё не применено.").foregroundStyle(Brand.secondaryInk)
                        Button("Проверить результат") { Task { await model.refreshOwners() } }.disabled(model.ownerBusy)
                        if model.canSaveOwnerObjectResult(objectID) {
                            Button("Сохранить результат") { Task { await model.retrySavingOwnerObjectResult(server: server, objectID: objectID) } }.disabled(model.ownerBusy)
                        } else if !object.sent && object.pending == .create && object.routing["device_id_ref"] != nil {
                            Button("Повторить создание объекта") { Task { await model.retryPreparedOwnerObject(server: server, objectID: objectID) } }.disabled(model.ownerBusy)
                        } else if !object.sent {
                            Button("Отменить изменение", role: .destructive) {
                                model.cancelOwnerObjectChange(server: server, objectID: objectID)
                                if self.object == nil { dismiss() }
                            }.disabled(model.ownerBusy)
                        }
                    } else if object.revision == nil {
                        Text("Для безопасного изменения сначала обновите данные. Сервер должен поддерживать проверку версии объекта.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                }
                Section {
                    Button("Сохранить название") {
                        Task { if await model.renameOwnerObject(server: server, objectID: objectID, label: label) { dismiss() } }
                    }.disabled(model.ownerBusy || object.available == false || object.pending != nil || object.revision == nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let did = object.bleDeviceID {
                        NavigationLink("Bluetooth-доступ гостей") { BLEPermissionsScreen(server: server, deviceID: did) }
                    }
                    Button("Удалить объект", role: .destructive) { deleting = true }.disabled(model.ownerBusy || object.available == false || object.pending != nil)
                }
            }
        }
        .navigationTitle("Настройка объекта").navigationBarTitleDisplayMode(.inline)
        .task {
            if let owner, let object { label = (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "" }
            if showDeleteOnLaunch { deleting = true }
        }
        .confirmationDialog("Удалить объект с сервера? Гости потеряют доступ к нему.", isPresented: $deleting, titleVisibility: .visible) {
            Button("Удалить объект", role: .destructive) {
                Task { await model.deleteOwnerObject(server: server, objectID: objectID); if object == nil { dismiss() } }
            }
        }
    }
}
