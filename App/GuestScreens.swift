import SwiftUI
import EntrixyCore

struct ControlScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    let addKey: () -> Void
    private var entries: [CatalogObject] {
        model.controlObjects.filter { query.isEmpty || model.objectLabel($0).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        Group {
            if model.controlObjects.isEmpty {
                EmptyScreen(image: "icon-key", title: "Ваши объекты", detail: "Добавьте свой объект в настройках или ключ, полученный от владельца.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.controlObjects.contains(where:{ (try? model.automationContext(.object($0.target)).template.geoEnabled) == true }) {
                            HomeLocationWarning(sensors:model.automationSensors)
                        }
                        PromotionCard(service:model.promotions)
                        ForEach(entries) { entry in
                            switch entry {
                            case let .owned(owner, object):
                                OwnerCatalogControlCard(control: model.ownerControl, ble: model.bleControl, owner: owner, object: object)
                            case let .received(guest, object): GuestCatalogControlCard(guest: guest, object: object)
                            }
                        }
                        if !query.isEmpty && entries.isEmpty {
                            Text("Ничего не найдено").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32)
                        }
                    }.padding(20).measureControlContent()
                }.background(Color(uiColor: .systemGroupedBackground))
                    .refreshable { await model.refreshOwners(); await model.refresh(); model.promotions.activate() }
                    .modifier(HomeWidgetHint())
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Найти объект")
        .navigationTitle(ProductText.string("tab_actions"))
        .onAppear { model.automation.setWorking(true) }
        .onDisappear { model.automation.setWorking(false) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: addKey) { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить ключ").disabled(!model.storageReady || model.busy)
            }
        }
        .overlay(alignment: .bottom) { if model.busy { ProgressView().padding() } }
    }
}

private struct GuestCatalogControlCard: View {
    @EnvironmentObject private var model: AppModel
    let guest: SavedGuest
    let object: GuestObject
    private var entry: CatalogObject { .received(guest, object) }
    var body: some View {
        ObjectControlCard(automation:model.automation,entry:entry,accessibilityText:model.objectLabel(entry)+". "+model.objectActionTitle(guestID:guest.id,object:object),action:{
            guard let intent = model.actionIntent(guestID: guest.id, object: object) else { return false }
            if intent.policy.confirmation || intent.policy.authentication != nil { model.actionPrompt = .guest(intent) }
            else { Task { await model.execute(intent) } }
            return true
        }) {
            HStack(spacing: 16) {
                CatalogStatusAvatar(entry: entry, control: model.ownerControl)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.objectLabel(entry)).font(.headline).foregroundStyle(.primary)
                    ObjectSourceLabel(entry: entry)
                    if guest.paused { Text("Доступ приостановлен").font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    if let rejection = model.actionRejections[guest.id + "|" + object.id] {
                        Text(rejection.message).font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    BLEGuestActionMessage(model: model.bleGuestControl, actionKey: guest.id + "|" + object.id)
                    if let text = model.actionMessages[guest.id + "|" + object.id] {
                        Text(text).font(.subheadline).foregroundStyle(Brand.secondaryInk).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
            .modifier(ActionRejectionFeedback(rejection: model.actionRejections[guest.id + "|" + object.id]))
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

enum SettingsTab: String, CaseIterable {
    case objects = "Объекты", keys = "Ключи", sounds = "Звуки", system = "Система"
    var title: String {
        switch self {
        case .objects: return ProductText.string("settings_tab_objects")
        case .keys: return ProductText.string("settings_tab_keys")
        case .sounds: return ProductText.string("settings_tab_sounds")
        case .system: return ProductText.string("settings_tab_system")
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("entrixy.appearance") private var appearance = "system"
    @State private var selected: SettingsTab = .objects
    @State private var showKey = false
    @State private var showCodeSettings = false
    @State private var addingKey = false
    @State private var addingObject = false
    @State private var createdDevice: ObjectReference?
    @State private var showingCreatedDevice = false
    @State private var keyInput = ""
    var body: some View {
        VStack(spacing: 0) {
            PhoneReadinessCard(service:model.phoneReadiness,sensors:model.automationSensors)
            Picker("Раздел настроек", selection: $selected) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12)
                .accessibilityIdentifier("settings-sections")
            List {
                switch selected {
                case .objects:
                    if model.catalogObjects().isEmpty { Text("Пока нет объектов").foregroundStyle(Brand.secondaryInk) }
                    ObjectSettingsRows(entries: model.catalogObjects())
                    Section {
                        Button(ProductText.string("settings_add_object")) { addingObject = true }.buttonStyle(SecondaryActionStyle()).actionListRow()
                            .disabled(!model.storageReady || model.ownerBusy)
                    }
                case .keys:
                    if model.guests.isEmpty && model.androidPendingGuests.isEmpty { Text("Пока нет полученных ключей").foregroundStyle(Brand.secondaryInk) }
                    ForEach(model.androidPendingGuests) { source in
                        ImportedGuestKeyRow(source:source,manager:model.backups)
                    }
                    ForEach(model.guests) { guest in
                        NavigationLink { KeyDetailScreen(guestID: guest.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(guest.invite.server).font(.headline)
                                Text("Объектов: \(guest.objects.count)").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                                ConnectionLabel(guestID: guest.id, paused: guest.paused)
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("received-key-" + guest.id)
                    }
                    Section {
                        Button(ProductText.string("settings_add_key")) { keyInput = ""; addingKey = true }.buttonStyle(PrimaryActionStyle())
                            .actionListRow()
                    }
                    Section { NavigationLink("Ожидаемые ключи") { DelegationInboxScreen() } }
                case .sounds:
                    SoundSettingsRows()
                case .system:
                    DiagnosticSettingsSection(service:model.diagnostics)
                    Section {
                        ForEach(["system","light","dark"],id:\.self) { choice in
                            Button { appearance = choice } label: {
                                HStack(spacing:12) {
                                    Image(systemName:appearance == choice ? "largecircle.fill.circle" : "circle")
                                    Text(ProductText.string("theme_" + choice)).frame(maxWidth:.infinity,alignment:.leading)
                                }.foregroundStyle(Brand.ink).frame(minHeight:44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("theme-"+choice).accessibilityAddTraits(appearance == choice ? .isSelected : [])
                        }
                    } header: { Text(ProductText.string("theme_section")) }
                    AppCodeSettingsSection()
                    BackupSettingsSection(flow:model.backupPresentation)
                    ServerSettingsSection()
                    if model.privacyRouter != nil { NetworkPrivacySettingsSection(sensors:model.automationSensors) }
                    Section {
                        NavigationLink("Сообщения") { MessagesScreen() }
                        NavigationLink("Лицензии") { LicenseScreen() }
                        KeyValueRow(title: "Версия", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    }
                    DeveloperSettingsSection(service:model.diagnostics)
                }
            }.scrollContentBackground(.hidden).compactListSections()
                .refreshable { if selected == .objects { await model.refreshOwners() }; await model.refresh() }
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle(ProductText.string("tab_settings"))
            .toolbar { if selected == .objects && model.catalogObjects().count > 1 { EditButton().accessibilityLabel("Порядок объектов") } }
            .navigationDestination(isPresented: $showCodeSettings) { AppEntryLockSettings() }
            .navigationDestination(isPresented: $showKey) {
                if let guest = model.guests.first { KeyDetailScreen(guestID: guest.id) }
            }
            .sheet(isPresented: $addingKey) { KeyImportScreen(input: $keyInput) }
            .sheet(isPresented: $addingObject, onDismiss: {
                if case let .owned(server, id) = createdDevice,
                   (try? model.ownerDeviceCredentials(server: server, objectID: id)) != nil { showingCreatedDevice = true }
            }) { AddCatalogObjectScreen(completion: { createdDevice = $0 }) }
            .sheet(isPresented: $showingCreatedDevice, onDismiss: { createdDevice = nil }) {
                if case let .owned(server, id) = createdDevice,
                   let credentials = try? model.ownerDeviceCredentials(server: server, objectID: id) {
                    DeviceCredentialsSheet(credentials: credentials, server: server)
                }
            }
            .task {
                if let requested = model.settingsRequest { selected = requested; model.settingsRequest = nil }
                #if DEBUG && targetEnvironment(simulator)
                if let scenario = ActionCaptureScenario.current, [ActionCaptureScenario.appCodeSetup, .appCodeSettings].contains(scenario) { selected = .system; showCodeSettings = true }
                if let route = StageTwoCapture.current {
                    selected = route.settingsTab
                    showKey = route == .keyDetail
                    showCodeSettings = route == .codeSettings
                    if route == .addServer { model.serverPrompt = ServerSettingsPrompt(action:.configure(nil,initial:"entrixy.com")) }
                    addingObject = route == .addObject
                }
                #endif
                if PreviewRouting.keyDetail && !model.guests.isEmpty { selected = .keys; showKey = true }
            }
            .onChange(of:model.settingsRequest) { requested in if let requested { selected = requested; model.settingsRequest = nil } }
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
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignMetrics.sectionGap) {
                    VStack(alignment: .leading, spacing: 12) {
                        KeyValueRow(title: "Сервер", value: guest.invite.server)
                        Divider()
                        KeyValueRow(title: "Объектов", value: String(guest.objects.count))
                        Divider()
                        ConnectionLabel(guestID: guest.id, paused: guest.paused)
                        if let date = guest.checkedAt {
                            Divider()
                            KeyValueRow(title: "Обновлено", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        Button { Task { await model.refresh() } } label: {
                            Label("Обновить данные", systemImage: "arrow.clockwise")
                        }.buttonStyle(SecondaryActionStyle()).disabled(model.busy)
                        Button("Удалить ключ с iPhone", role: .destructive) { removing = true }.buttonStyle(SecondaryActionStyle()).disabled(model.busy)
                        Text("Удаление уберёт ключ и его объекты из этого приложения. Повторно добавить ключ можно по исходной ссылке.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }.padding(DesignMetrics.pageInset)
                }.background(Color(uiColor: .systemGroupedBackground))
            } else { EmptyScreen(image: "icon-key", title: "Ключ удалён", detail: "Вы можете добавить его снова по ссылке владельца.") }
        }
        .navigationTitle("Полученный ключ").navigationBarTitleDisplayMode(.inline)
        .appConfirmationDialog("Удалить ключ?",message:"Удалить ключ и его объекты с этого iPhone?",actionTitle:"Удалить ключ",destructive:true,isPresented:$removing) {
            model.removeKey(guestID); if !model.guests.contains(where: { $0.id == guestID }) { dismiss() }
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
            .buttonStyle(SecondaryActionStyle()).foregroundStyle(Brand.ink).disabled(model.journal.isEmpty)
            .padding(.horizontal, DesignMetrics.pageInset).padding(.top, 12).padding(.bottom, 16)
            if model.journal.isEmpty {
                Text(ProductText.string("journal_empty"))
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
        .background(Color(uiColor: .systemGroupedBackground)).navigationTitle(ProductText.string("tab_journal"))
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
            guard ActionCaptureScenario.current == nil && StageTwoCapture.current == nil else { return }
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
