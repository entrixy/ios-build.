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
                EmptyScreen(image: "icon-key", title: ProductText.string("help_section_objects"), detail: ProductText.string("ios_control_empty_hint"))
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
                            Text(ProductText.string("ios_search_empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32)
                        }
                    }.padding(20).measureControlContent()
                }.background(Color(uiColor: .systemGroupedBackground))
                    .refreshable { await model.refreshOwners(); await model.refresh(); model.promotions.activate() }
                    .modifier(HomeWidgetHint())
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: ProductText.string("ios_search_objects"))
        .navigationTitle(ProductText.string("tab_actions"))
        .onAppear { model.automation.setWorking(true) }
        .onDisappear { model.automation.setWorking(false) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: addKey) { Image(systemName: "plus") }
                    .accessibilityLabel(ProductText.string("add_key_title")).disabled(!model.storageReady || model.busy)
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
                    if guest.paused { Text(ProductText.string("ios_access_paused")).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    if let rejection = model.actionRejections[guest.id + "|" + object.id] {
                        Text(ProductText.systemMessage(rejection.message)).font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    BLEGuestActionMessage(model: model.bleGuestControl, actionKey: guest.id + "|" + object.id)
                    if let text = model.actionMessages[guest.id + "|" + object.id] {
                        Text(ProductText.systemMessage(text)).font(.subheadline).foregroundStyle(Brand.secondaryInk).fixedSize(horizontal: false, vertical: true)
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
            Text(model.connection(for: guestID) == .unavailable ? ProductText.string("ios_key_unavailable") : (paused ? ProductText.string("ios_access_paused") : model.connection(for: guestID).title))
        }.font(.subheadline).foregroundStyle(Brand.secondaryInk)
    }
    private var color: Color {
        if model.connection(for: guestID) == .unavailable || paused { return AppPalette.statusOffline }
        switch model.connection(for: guestID) {
        case .connected: return AppPalette.statusReady
        case .connecting: return AppPalette.statusBlue
        case .offline, .unavailable: return AppPalette.statusOffline
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
    @State private var removingReceivedKey: String?
    @State private var showCodeSettings = false
    @State private var showingLocalReset = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var captureConfigured = false
    #endif
    @State private var addingKey = false
    @State private var addingObject = false
    @State private var createdDevice: ObjectReference?
    @State private var showingCreatedDevice = false
    @State private var keyInput = ""
    var body: some View {
        VStack(spacing: 0) {
            PhoneReadinessCard(service:model.phoneReadiness,sensors:model.automationSensors)
            Picker(ProductText.string("ios_settings_sections"), selection: $selected) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12)
                .accessibilityIdentifier("settings-sections")
            List {
                switch selected {
                case .objects:
                    if model.catalogObjects().isEmpty { Text(ProductText.string("ios_objects_empty")).foregroundStyle(Brand.secondaryInk) }
                    ObjectSettingsRows(entries: model.catalogObjects())
                    Section {
                        Button(ProductText.string("settings_add_object")) { addingObject = true }.buttonStyle(SecondaryActionStyle()).actionListRow()
                            .disabled(!model.storageReady || model.ownerBusy)
                    }
                case .keys:
                    if model.receivedKeyRecords.isEmpty { Text(ProductText.string("ios_keys_empty")).foregroundStyle(Brand.secondaryInk).accessibilityIdentifier("received-keys-empty") }
                    ForEach(model.receivedKeyRecords) { record in
                        ReceivedKeySettingsRow(record: record, backups: model.backups, inbox: model.delegationInbox) { removingReceivedKey = record.id }
                    }
                    Section {
                        Button(ProductText.string("settings_add_key")) { keyInput = ""; addingKey = true }.buttonStyle(PrimaryActionStyle())
                            .actionListRow()
                    }
                    Section { NavigationLink(ProductText.string("ios_pending_keys")) { DelegationInboxScreen() } }
                case .sounds:
                    SoundSettingsRows()
                case .system:
                    DiagnosticSettingsSection(service:model.diagnostics)
                    Section {
                        ForEach(["system","light","dark"],id:\.self) { choice in
                            Button { appearance = choice } label: {
                                HStack(spacing:12) {
                                    Image(systemName:appearance == choice ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(appearance == choice ? AppPalette.selected : Brand.secondaryInk)
                                    Text(ProductText.string("theme_" + choice)).frame(maxWidth:.infinity,alignment:.leading)
                                }.foregroundStyle(Brand.ink).frame(minHeight:44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("theme-"+choice).accessibilityAddTraits(appearance == choice ? .isSelected : [])
                        }
                    } header: { Text(ProductText.string("theme_section")) }
                    AppCodeSettingsSection(showReset:{ showingLocalReset = true })
                    BackupSettingsSection(flow:model.backupPresentation)
                    ServerSettingsSection()
                    if model.privacyRouter != nil { NetworkPrivacySettingsSection(sensors:model.automationSensors) }
                    Section {
                        NavigationLink(ProductText.string("ios_messages")) { MessagesScreen() }
                        NavigationLink(ProductText.string("ios_licenses")) { LicenseScreen() }
                        KeyValueRow(title: ProductText.string("ios_version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    }
                    Section {
                        AppPrivacyPolicyLink().actionListRow()
                        NavigationLink(ProductText.string("ios_deletion_title")) { DataDeletionServersScreen() }
                            .accessibilityIdentifier("data-deletion-settings")
                    }
                    DeveloperSettingsSection(service:model.diagnostics)
                }
            }.scrollContentBackground(.hidden).compactListSections()
                .refreshable { if selected == .objects { await model.refreshOwners() }; await model.refresh() }
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle(ProductText.string("tab_settings"))
            .navigationDestination(isPresented: $showCodeSettings) { AppEntryLockSettings() }
            .appConfirmationDialog(ProductText.string("guest_delete_title"),message:ProductText.string("guest_delete_warning"),actionTitle:ProductText.string("guest_delete_confirm"),destructive:true,
                isPresented:Binding(get:{ removingReceivedKey != nil },set:{ if !$0 { removingReceivedKey = nil } })) {
                    if let id = removingReceivedKey { model.removeReceivedKeyRecord(id) }
                }
            .sheet(isPresented: $addingKey) { KeyImportScreen(input: $keyInput) }
            .sheet(isPresented: $showingLocalReset) { LocalResetScreen() }
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
                if !captureConfigured {
                captureConfigured = true
                if let scenario = ActionCaptureScenario.current, [ActionCaptureScenario.appCodeSetup, .appCodeSettings].contains(scenario) { selected = .system; showCodeSettings = true }
                if ActionCaptureScenario.current == .keyDetail { selected = .keys }
                if let route = StageTwoCapture.current {
                    selected = route.settingsTab
                    showCodeSettings = route == .codeSettings
                    if route == .addServer { model.serverPrompt = ServerSettingsPrompt(action:.configure(nil,initial:"entrixy.com")) }
                    addingObject = route == .addObject
                }
                }
                #endif
                if PreviewRouting.keyDetail && !model.guests.isEmpty { selected = .keys }
            }
            .onChange(of:model.settingsRequest) { requested in if let requested { selected = requested; model.settingsRequest = nil } }
    }
}

struct JournalScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    private var text: String {
        model.journal.reversed().map { entry in
            let date = ProductText.date(entry.date,dateStyle:.numeric,timeStyle:.standard)
            return "\(date)  \(entry.who) → \(model.journalLabel(entry))" + (entry.result.isEmpty ? "" : " · " + entry.result)
        }.joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 0) {
            EqualActionRow {
                ShareLink(item: text) { JournalToolbarItem(symbol: "square.and.arrow.up", title: ProductText.string("btn_share")) }
                Button { UIPasteboard.general.string = text; copied = true } label: {
                    JournalToolbarItem(symbol: "doc.on.doc", title: ProductText.string("btn_copy"))
                }
                Button(role: .destructive) { model.clearJournal() } label: { JournalToolbarItem(symbol: "trash", title: ProductText.string("journal_clear")) }
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
                            Text(ProductText.systemMessage(entry.result)).font(.subheadline)
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
                Text(ProductText.string("ios_journal_copied")).font(.subheadline)
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
            .navigationTitle(ProductText.string("ios_licenses")).navigationBarTitleDisplayMode(.inline)
    }
    private var license: String {
        ["MaterialIcons-LICENSE", "VLCKit-LICENSE"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n\n")
    }
}

private struct BLEGuestActionMessage: View {
    @ObservedObject var model: BLEGuestControlModel
    let actionKey: String
    var body: some View {
        if let text = model.messages[actionKey] {
            Text(ProductText.systemMessage(text)).font(.subheadline).foregroundStyle(Brand.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
    }
}
