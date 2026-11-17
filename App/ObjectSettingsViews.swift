import SwiftUI
import EntrixyCore

/// Product destinations keep the owning server/key in the route. An expanded
/// card is not a generic object detail page and never performs a physical action.
enum ObjectSettingsTask: Identifiable {
    case edit(ObjectReference)
    case rename(ObjectReference)
    case automation(ObjectReference)
    var target: ObjectReference { switch self { case .edit(let target), .rename(let target), .automation(let target): return target } }
    var id: String { switch self { case .edit: return "edit:" + target.id; case .rename: return "rename:" + target.id; case .automation: return "automation:" + target.id } }
}

struct CatalogAvatar: View {
    let entry: CatalogObject
    let size: CGFloat
    var body: some View {
        switch entry {
        case let .owned(owner, object): OwnerObjectAvatar(object: object, masterKey: owner.masterKey, size: size)
        case let .received(guest, object): ObjectAvatar(object: object, guestID: guest.id, size: size)
        }
    }
}

struct CatalogStatusAvatar: View {
    @EnvironmentObject private var model: AppModel
    let entry: CatalogObject
    @ObservedObject var control: OwnerControlModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = model.objectAvailability(entry)
            CatalogAvatar(entry: entry, size: 56)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(color(status)).frame(width: 10, height: 10)
                        .offset(x: -8, y: -8)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(description(status))
        }
    }
    private func color(_ status: CatalogAvailability) -> Color {
        switch status { case .ready: return .green; case .connecting: return .orange; case .neutral: return Brand.primary; case .offline, .unknown: return .red }
    }
    private func description(_ status: CatalogAvailability) -> String {
        switch status {
        case .ready: return "Объект доступен"
        case .offline: return "Объект недоступен"
        case .connecting: return "Подключение"
        case .neutral: return "HTTPS-запрос"
        case .unknown: return "Доступность ещё не проверена"
        }
    }
}

struct ObjectSourceLabel: View {
    let entry: CatalogObject
    private var symbol: String {
        switch entry.kind { case "ble": return "wave.3.right"; case "call": return "phone"; case "webhook": return "link"; default: return "cpu" }
    }
    var body: some View {
        Label(entry.sourceLabel, systemImage: symbol).font(.subheadline).foregroundStyle(Brand.secondaryInk)
    }
}

struct ObjectSettingsRows: View {
    @EnvironmentObject private var model: AppModel
    let entries: [CatalogObject]
    @State private var expanded = Set<ObjectReference>()
    @State private var task: ObjectSettingsTask?

    var body: some View {
        ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button { model.objectAvatarTarget = entry.target } label: {
                        CatalogAvatar(entry:entry,size:56).frame(width:56,height:56).contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(width:56,height:56).contentShape(Rectangle())
                        .accessibilityLabel(ProductText.string("avatar_picker_title"))
                        .accessibilityIdentifier("object-avatar-" + entry.target.id).disabled(entry.deletionPending)
                    Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expanded.contains(entry.target) { expanded.remove(entry.target) }
                        else { expanded.insert(entry.target) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.objectLabel(entry)).font(.headline).foregroundStyle(Brand.ink)
                            ObjectSourceLabel(entry: entry)
                            if case let .owned(_, object) = entry, object.pending != nil {
                                Text(object.sent ? "Ожидает подтверждения сервера" : "Изменение не применено")
                                    .font(.caption).foregroundStyle(Brand.secondaryInk)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: expanded.contains(entry.target) ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(Brand.secondaryInk)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("object-settings-" + entry.target.id)
                    .accessibilityValue(expanded.contains(entry.target) ? "Развёрнут" : "Свёрнут")
                }
                if expanded.contains(entry.target) {
                    Divider()
                    HStack(spacing: 10) {
                        Button { task = entry.kindTask } label: {
                            Image(systemName: entry.isOwned ? "gearshape" : "pencil").font(.title3).frame(maxWidth: .infinity)
                        }.buttonStyle(SecondaryActionStyle())
                            .accessibilityLabel(entry.isOwned ? "Настройки" : "Название")
                            .accessibilityIdentifier("object-edit-" + entry.target.id)
                        Button { task = .automation(entry.target) } label: {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.title3).frame(maxWidth: .infinity)
                        }.buttonStyle(SecondaryActionStyle()).accessibilityLabel(ProductText.string("automation_icon_desc"))
                        if entry.isOwned && entry.kind == "ble" {
                            Button { model.bleInformationTarget = entry.target } label: {
                                Image(systemName:"info.circle").font(.title3).frame(maxWidth:.infinity)
                            }.buttonStyle(SecondaryActionStyle()).accessibilityLabel(ProductText.string("set_info"))
                                .accessibilityIdentifier("object-info-" + entry.target.id)
                        }
                        Button(role: .destructive) { model.objectRemovalTarget = entry.target } label: {
                            Image(systemName: "trash").font(.title3).frame(maxWidth: .infinity)
                        }.buttonStyle(SecondaryActionStyle())
                            .accessibilityLabel(entry.isOwned ? "Удалить" : "Скрыть")
                            .disabled(model.ownerBusy || model.busy || entry.deletionPending)
                    }
                    if case let .owned(_, object) = entry, let message = model.ownerObjectMessages[object.id] {
                        Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    }
                }
            }.padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        }.onMove { offsets, index in
            var targets = entries.map(\.target); targets.move(fromOffsets: offsets, toOffset: index)
            model.reorderObjects(targets)
        }
        .sheet(item: $task) { task in
            switch task {
            case .edit(let target):
                if case let .owned(server, id) = target {
                    NavigationStack { OwnerObjectEditor(server: server, objectID: id) }
                        .sheetDismissFooter(disabled: model.ownerBusy) { self.task = nil }
                }
            case .rename(let target): ReceivedObjectNameScreen(target: target)
            case .automation(let target): AutomationEditor(destination: .object(target))
            }
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if let route = StageTwoCapture.current, [StageTwoCapture.ownerExpanded, .guestExpanded, .ownerBLEObjects].contains(route), let first = entries.first {
                expanded.insert(first.target)
            }
            #endif
        }
    }

}

/// SettingsScreen.infoBleId: same owner-only fields and no invented readings.
struct BLEInformationDialog: View {
    @EnvironmentObject private var model: AppModel
    let target: ObjectReference
    var body: some View {
        AppDialogSurface {
            TimelineView(.periodic(from:.now,by:1)) { timeline in
                VStack(alignment:.leading,spacing:16) {
                    Text(model.catalogObject(target).map { model.objectLabel($0) } ?? ProductText.string("set_info"))
                        .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    if let entry = model.catalogObject(target), case .owned(let owner,_) = entry,
                       model.ownerAccessIsUsable(owner.server), let info = model.bleInformation[target] {
                        KeyValueRow(title:ProductText.string("ble_info_battery"),value:"\(info.batteryPercent)%")
                        KeyValueRow(title:ProductText.string("ble_info_hw"),value:hardware(info.hardwareModel))
                        KeyValueRow(title:ProductText.string("ble_info_fw"),value:"v\(info.firmwareMajor).\(info.firmwareMinor)")
                        KeyValueRow(title:ProductText.string("ble_info_sleep"),value:info.sleepSeconds.map { $0 == 0 ? ProductText.string("ble_info_sleep_none") : ProductText.string("ble_info_sleep_fmt",Int($0)) } ?? ProductText.string("ble_info_sleep_none"))
                        KeyValueRow(title:ProductText.string("ble_info_state"),value:status(info.statusFlags))
                        Text(ProductText.string("ble_info_updated_fmt",max(0,Int(timeline.date.timeIntervalSince(info.observedAt)))))
                            .font(.footnote).foregroundStyle(Brand.secondaryInk)
                    } else { Text(ProductText.string("ble_info_no_data")).font(.body) }
                    Button(ProductText.string("btn_close")) { model.bleInformationTarget = nil }.buttonStyle(SecondaryActionStyle())
                }
            }
        }
    }
    private func hardware(_ value: UInt8) -> String {
        switch value { case 0: return "Generic / unknown"; case 1: return "ESP32-C3"; case 2: return "ESP32-S3"; case 3: return "ESP32-C6"; default: return "Custom (#\(value))" }
    }
    private func status(_ value: UInt8) -> String {
        let fields: [(UInt8,String)] = [(1,"relay"),(2,"lowbat"),(4,"clock"),(8,"tamper"),(16,"ntp")]
        let flags = fields.filter { value & $0.0 != 0 }.map { ProductText.string("ble_info_flag_" + $0.1) }
        return flags.isEmpty ? ProductText.string("ble_info_state_ok") : flags.joined(separator:", ")
    }
}

private extension CatalogObject {
    var isOwned: Bool { if case .owned = self { return true }; return false }
    var kindTask: ObjectSettingsTask { isOwned ? .edit(target) : .rename(target) }
    var deletionPending: Bool {
        if case let .owned(owner, object) = self { return object.pending != nil || object.available == false || owner.isMoving(object.id) }
        return false
    }
}

private struct ReceivedObjectNameScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: ObjectReference
    @State private var label = ""
    @State private var initialized = false
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppField("Название") {
                        TextField("Название",text:$label).autocorrectionDisabled().focused($editing).submitLabel(.done)
                            .onSubmit { editing = false }
                            .onChange(of:label) { label = String($0.replacingOccurrences(of:"\n",with:"").replacingOccurrences(of:"\r",with:"").prefix(64)) }
                    }
                } footer: { Text("Название изменится только на этом iPhone.") }
                Section {
                    Button("Сохранить") { let name = label; editing = false; if model.renameReceivedObject(target,label:name) { dismiss() } }
                        .buttonStyle(PrimaryActionStyle()).actionListRow().disabled(model.busy || model.catalogObject(target) == nil)
                }
            }.navigationTitle("Название объекта").navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(disabled: model.busy) { dismiss() }
                .task {
                    guard !initialized else { return }; initialized = true
                    if let entry = model.catalogObject(target) { label = model.objectLabel(entry) }
                }
        }
    }
}

struct AddCatalogObjectScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var completion: ((ObjectReference?) -> Void)? = nil
    private func finish(_ target: ObjectReference?) { completion?(target); dismiss() }
    var body: some View {
        AddOwnerObjectScreen(server:model.selectedOwnerServer,completion:finish)
    }
}


struct ObjectRemovalConfirmation: View {
    @EnvironmentObject private var model: AppModel
    let target: ObjectReference
    private var received: Bool { if case .received = target { return true }; return false }
    var body: some View {
        AppConfirmationDialog(title: received ? "Скрыть объект?" : "Удалить объект?",
            message: message, actionTitle: received ? "Скрыть объект" : "Удалить объект", destructive: true,
            cancel: { model.objectRemovalTarget = nil }, confirm: {
                guard model.canManageGuestAccess, model.catalogObject(target) != nil else { model.objectRemovalTarget = nil; return }
                switch target {
                case let .owned(server, objectID):
                    model.objectRemovalTarget = nil
                    Task { await model.deleteOwnerObject(server: server, objectID: objectID) }
                case .received:
                    if model.hideReceivedObject(target) { model.objectRemovalTarget = nil }
                }
            })
    }
    private var message: String {
        let label = model.catalogObject(target).map { "«" + model.objectLabel($0) + "». " } ?? ""
        return label + (received ? "Ключ и остальные объекты останутся. Повторное добавление исходного ключа вернёт скрытый объект." : "Гости потеряют доступ к этому объекту.")
    }
}
