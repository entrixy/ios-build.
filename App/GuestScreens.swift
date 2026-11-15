import SwiftUI
import EntrixyCore

struct ControlScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var actionIntent: ActionIntent?
    let addKey: () -> Void

    private func matches(_ object: GuestObject) -> Bool {
        query.isEmpty || object.label.localizedCaseInsensitiveContains(query)
    }
    var body: some View {
        Group {
            if model.guests.isEmpty && model.owners.allSatisfy({ ($0.objects ?? []).allSatisfy({ !$0.ownerCardAvailable }) }) {
                EmptyScreen(image: "icon-key", title: "Ваши объекты", detail: "Добавьте свой объект в настройках или ключ, полученный от владельца.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        OwnerControlSection(control: model.ownerControl, query: query, ble: model.bleControl)
                        if !model.guests.isEmpty { Text("Полученные объекты").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(model.guests) { guest in
                            if guest.objects.isEmpty && query.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(guest.invite.server).font(.headline)
                                    ConnectionLabel(guestID: guest.id, paused: guest.paused)
                                    Text("Объекты появятся после обновления данных ключа.").font(.subheadline).foregroundStyle(.secondary)
                                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 22))
                            }
                            ForEach(guest.objects.filter(matches)) { object in
                                Button {
                                    guard let intent = model.actionIntent(guestID: guest.id, object: object) else { return }
                                    if intent.policy.confirmation || intent.policy.authentication != nil { actionIntent = intent }
                                    else { Task { await model.execute(intent) } }
                                } label: {
                                    HStack(spacing: 16) {
                                        ObjectAvatar(object: object, guestID: guest.id, size: 56)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(object.label).font(.headline).foregroundStyle(.primary)
                                            if object.kind == "ble" {
                                                Text(guest.paused ? "Доступ приостановлен" : "Bluetooth").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                                            } else if !guest.paused && model.connection(for: guest.id) == .connected {
                                                Text(model.objectConnectionTitle(guestID: guest.id, object: object))
                                                    .font(.subheadline).foregroundStyle(Brand.secondaryInk)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            } else { ConnectionLabel(guestID: guest.id, paused: guest.paused) }
                                            if let rejection = model.actionRejections[guest.id + "|" + object.id],
                                               object.kind == "ble" || rejection.message.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) != model.objectConnectionTitle(guestID: guest.id, object: object) {
                                                Text(rejection.message).font(.subheadline).foregroundStyle(.red)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            BLEGuestActionMessage(model: model.bleGuestControl, actionKey: guest.id + "|" + object.id)
                                            if let text = model.actionMessages[guest.id + "|" + object.id] {
                                                Text(text).font(.subheadline).foregroundStyle(Brand.secondaryInk).fixedSize(horizontal: false, vertical: true)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 22))
                                }.buttonStyle(CardActionStyle())
                                    .modifier(ActionRejectionFeedback(rejection: model.actionRejections[guest.id + "|" + object.id]))
                                    .accessibilityLabel(object.label + ". " + model.objectActionTitle(guestID: guest.id, object: object))
                                    .accessibilityHint("Выполнить действие с объектом")
                            }
                        }
                        if !query.isEmpty && !model.guests.flatMap(\.objects).contains(where: matches)
                            && !model.owners.contains(where: { owner in
                                (owner.objects ?? []).contains { object in
                                    let label = (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? ""
                                    return object.numberID != nil && object.pending == nil && object.available != false && label.localizedCaseInsensitiveContains(query)
                                }
                            }) {
                            Text("Ничего не найдено").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32)
                        }
                    }.padding(20)
                }.background(Color(uiColor: .systemGroupedBackground))
                    .refreshable { await model.refresh() }
            }
        }
        .sheet(item: $actionIntent) { ActionConfirmation(intent: $0) }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Найти объект")
        .navigationTitle("Управление")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: addKey) { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить ключ").disabled(!model.storageReady || model.busy)
            }
        }
        .overlay(alignment: .bottom) { if model.busy { ProgressView().padding() } }
    }
}

struct ConnectionLabel: View {
    @EnvironmentObject private var model: AppModel
    let guestID: String
    let paused: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(model.connection(for: guestID) == .unavailable ? "Ключ недоступен" : (paused ? "Доступ приостановлен" : model.connection(for: guestID).title))
        }.font(.subheadline).foregroundStyle(Brand.secondaryInk)
    }
    private var color: Color {
        if model.connection(for: guestID) == .unavailable { return .red }
        if paused { return .orange }
        switch model.connection(for: guestID) {
        case .connected: return Color(red: 149.0/255, green: 193.0/255, blue: 31.0/255)
        case .connecting: return .orange
        case .offline, .unavailable: return .secondary
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("entrixy.appearance") private var appearance = "system"
    @State private var showKey = false
    var body: some View {
        List {
            Section("Полученные ключи") {
                if model.guests.isEmpty { Text("Пока нет полученных ключей").foregroundStyle(.secondary) }
                ForEach(model.guests) { guest in
                    NavigationLink { KeyDetailScreen(guestID: guest.id) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(guest.invite.server).font(.headline)
                            Text("Объектов: \(guest.objects.count)").font(.subheadline).foregroundStyle(.secondary)
                            ConnectionLabel(guestID: guest.id, paused: guest.paused)
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section("Мои объекты") {
                NavigationLink("Мои серверы") { OwnerServersScreen() }
            }
            Section("Оформление") {
                Picker("Тема", selection: $appearance) {
                    Text("Как в системе").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }
            }
            Section("Система") {
                KeyValueRow(title: "Приложение", value: "Entrixy для iOS")
                KeyValueRow(title: "Версия", value: "0.1.0")
                NavigationLink("Сообщения") { MessagesScreen() }
                NavigationLink("Ожидаемые ключи") { DelegationInboxScreen() }
                NavigationLink("Резервная копия") { BackupScreen(manager: model.backups) }
                NavigationLink("Лицензии") { LicenseScreen() }
            }
        }.navigationTitle("Настройки")
            .refreshable { await model.refresh() }
            .navigationDestination(isPresented: $showKey) {
                if let guest = model.guests.first { KeyDetailScreen(guestID: guest.id) }
            }
            .task {
                if PreviewRouting.keyDetail && !model.guests.isEmpty {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showKey = true
                }
            }
    }
}

struct KeyDetailScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    let guestID: String
    var body: some View {
        Group {
            if let guest = model.guests.first(where: { $0.id == guestID }) {
                List {
                    Section {
                        KeyValueRow(title: "Сервер", value: guest.invite.server)
                        KeyValueRow(title: "Объектов", value: String(guest.objects.count))
                        ConnectionLabel(guestID: guest.id, paused: guest.paused)
                        if let date = guest.checkedAt {
                            KeyValueRow(title: "Обновлено", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    Section {
                        Button { Task { await model.refresh() } } label: {
                            Label("Обновить данные", systemImage: "arrow.clockwise").foregroundStyle(Brand.ink)
                        }.buttonStyle(SecondaryActionStyle()).disabled(model.busy)
                    }
                    Section {
                        Button("Удалить ключ с iPhone", role: .destructive) { removing = true }.buttonStyle(SecondaryActionStyle()).disabled(model.busy)
                    } footer: { Text("Удаление уберёт ключ и его объекты из этого приложения. Повторно добавить ключ можно по исходной ссылке.").foregroundStyle(Brand.secondaryInk) }
                }
            } else { EmptyScreen(image: "icon-key", title: "Ключ удалён", detail: "Вы можете добавить его снова по ссылке владельца.") }
        }
        .navigationTitle("Полученный ключ").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Удалить ключ и его объекты с этого iPhone?", isPresented: $removing, titleVisibility: .visible) {
            Button("Удалить ключ", role: .destructive) { model.removeKey(guestID); if !model.guests.contains(where: { $0.id == guestID }) { dismiss() } }
        }
    }
}

struct JournalScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    private var text: String {
        model.journal.reversed().map { entry in
            let date = entry.date.formatted(date: .numeric, time: .standard)
            return "\(date)  \(entry.who) → \(model.journalLabel(entry))" + (entry.result.isEmpty ? "" : " · " + entry.result)
        }.joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ShareLink(item: text) { JournalToolbarItem(symbol: "square.and.arrow.up", title: "Поделиться") }
                Button { UIPasteboard.general.string = text; copied = true } label: {
                    JournalToolbarItem(symbol: "doc.on.doc", title: "Копировать")
                }
                Button(role: .destructive) { model.clearJournal() } label: { JournalToolbarItem(symbol: "trash", title: "Очистить") }
            }
            .buttonStyle(SecondaryActionStyle(surface: .clear)).foregroundStyle(Brand.ink).disabled(model.journal.isEmpty)
            .padding(.horizontal, DesignMetrics.pageInset).padding(.top, 12).padding(.bottom, 16)
            if model.journal.isEmpty {
                Text("Журнал пуст. Здесь будут появляться вызовы.")
                    .font(.body).foregroundStyle(Brand.secondaryInk)
                    .multilineTextAlignment(.center).padding(.horizontal, 32).padding(.top, 48)
                Spacer()
            } else {
                List(model.journal) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.subheadline.monospacedDigit()).foregroundStyle(Brand.ink)
                                .frame(width: 70, alignment: .trailing)
                            Text(entry.who).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(entry.date, format: .dateTime.day().month(.twoDigits))
                                .font(.caption).foregroundStyle(Brand.secondaryInk)
                                .frame(width: 70, alignment: .trailing)
                            Text(model.journalLabel(entry)).font(.body.weight(.medium)).foregroundStyle(Brand.ink)
                        }
                        if !entry.result.isEmpty {
                            Text(entry.result).font(.subheadline)
                                .foregroundStyle(entry.level == "danger" ? Color(uiColor: .systemRed) : Brand.secondaryInk)
                                .padding(.leading, 86)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: DesignMetrics.pageInset, bottom: 12, trailing: DesignMetrics.pageInset))
                    .listRowBackground(Color.clear)
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground)).navigationTitle("Журнал")
        .overlay(alignment: .bottom) {
            if copied {
                Text("Журнал скопирован").font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 16)
                    .allowsHitTesting(false).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            guard ActionCaptureScenario.current == nil else { return }
            #endif
            await model.passManager.reload()
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copied = false
        }
    }
}

private struct JournalToolbarItem: View {
    let symbol: String
    let title: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular))
            Text(title).font(.caption)
        }.frame(maxWidth: .infinity).frame(minHeight: 52).contentShape(Rectangle())
    }
}

struct KeyValueRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(Brand.secondaryInk)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).foregroundStyle(Brand.ink).multilineTextAlignment(.trailing)
        }.font(.body).padding(.vertical, 4)
    }
}

struct LicenseScreen: View {
    var body: some View {
        ScrollView { Text(license).font(.footnote).padding(20) }
            .navigationTitle("Лицензии").navigationBarTitleDisplayMode(.inline)
    }
    private var license: String {
        guard let url = Bundle.main.url(forResource: "MaterialIcons-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "Material Design icons · Google · Apache 2.0" }
        return text
    }
}

private struct BLEGuestActionMessage: View {
    @ObservedObject var model: BLEGuestControlModel
    let actionKey: String
    var body: some View {
        if let text = model.messages[actionKey] {
            Text(text).font(.subheadline).foregroundStyle(Brand.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
    }
}
