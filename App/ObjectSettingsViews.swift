import SwiftUI
import EntrixyCore

/// Product destinations keep the owning server/key in the route. An expanded
/// card is not a generic object detail page and never performs a physical action.
enum ObjectSettingsTask: Identifiable {
    case edit(ObjectReference)
    case rename(ObjectReference)
    var target: ObjectReference { switch self { case .edit(let target), .rename(let target): return target } }
    var id: String { switch self { case .edit: return "edit:" + target.id; case .rename: return "rename:" + target.id } }
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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expanded.contains(entry.target) { expanded.remove(entry.target) }
                        else { expanded.insert(entry.target) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        CatalogAvatar(entry: entry, size: 44)
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
                if expanded.contains(entry.target) {
                    Divider()
                    HStack(spacing: 10) {
                        Button { task = entry.kindTask } label: {
                            Label(entry.isOwned ? "Настройки" : "Название", systemImage: "pencil")
                        }.buttonStyle(SecondaryActionStyle())
                        Button(role: .destructive) { model.objectRemovalTarget = entry.target } label: {
                            Label(entry.isOwned ? "Удалить" : "Скрыть", systemImage: "trash")
                        }.buttonStyle(SecondaryActionStyle())
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
            }
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if let route = StageTwoCapture.current, [StageTwoCapture.ownerExpanded, .guestExpanded].contains(route), let first = entries.first {
                expanded.insert(first.target)
            }
            #endif
        }
    }

}

private extension CatalogObject {
    var isOwned: Bool { if case .owned = self { return true }; return false }
    var kindTask: ObjectSettingsTask { isOwned ? .edit(target) : .rename(target) }
    var deletionPending: Bool {
        if case let .owned(_, object) = self { return object.pending != nil || object.available == false }
        return false
    }
}

private struct ReceivedObjectNameScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: ObjectReference
    @State private var label = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppField("Название") { TextField("Название", text: $label).onChange(of: label) { label = String($0.prefix(64)) } }
                } footer: { Text("Название изменится только на этом iPhone.") }
                Section {
                    Button("Сохранить") { if model.renameReceivedObject(target, label: label) { dismiss() } }
                        .buttonStyle(PrimaryActionStyle()).actionListRow().disabled(model.busy || model.catalogObject(target) == nil)
                }
            }.navigationTitle("Название объекта").navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(disabled: model.busy) { dismiss() }
                .task { if let entry = model.catalogObject(target) { label = model.objectLabel(entry) } }
        }
    }
}

struct AddCatalogObjectScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if model.owners.filter({ !$0.registrationPending }).isEmpty {
            AddOwnerObjectScreen(server: model.owners.first?.server ?? "entrixy.com")
        } else if let owner = model.owners.first(where: { !$0.registrationPending }), model.owners.filter({ !$0.registrationPending }).count == 1 {
            AddOwnerObjectScreen(server: owner.server)
        } else {
            NavigationStack {
                List(model.owners.filter { !$0.registrationPending }) { owner in
                    NavigationLink(owner.server) { AddOwnerObjectScreen(server: owner.server, embedded: true) }
                }.navigationTitle("Сервер объекта").navigationBarTitleDisplayMode(.inline)
                    .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }
            }
        }
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
