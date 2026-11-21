import SwiftUI
import EntrixyCore

struct PassedAccessScreen: View {
    @EnvironmentObject private var app: AppModel
    var manager: PassManager? = nil
    var body: some View { PassedAccessContent(manager: manager ?? app.passManager) }
}
private struct PassedAccessContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: PassManager
    @State private var adding = false
    var body: some View {
        List {
            if let message = manager.message { Section { Text(message).foregroundStyle(Brand.secondaryInk) } }
            ForEach(app.passedAccess) { record in
                NavigationLink { PassedAccessDetail(manager: manager, accessID: record.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.label).font(.headline)
                        Text(passedAccessStatus(record)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    }.padding(.vertical, 5)
                }
            }
            if app.passedAccess.isEmpty { Text("Переданных ключей пока нет").foregroundStyle(Brand.secondaryInk) }
        }
        .navigationTitle("Переданный доступ").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus").accessibilityLabel("Передать доступ") }.disabled(manager.busy || app.guests.isEmpty || app.busy || app.ownerBusy) } }
        .refreshable { await manager.reload() }
        .task { await manager.reload() }
        .sheet(isPresented: $adding) { PassAccessForm(manager: manager) }
    }
}
private struct PassObjectOption: Identifiable {
    let source: SavedGuest
    let object: GuestObject
    let allowance: PassAllowance
    let existing: Bool
    var id: String { source.id + "|" + object.id }
    var maximumDepth: Int { max(0,allowance.depth - 1) }
    var maximumPool: Int { max(1,allowance.poolLeft - (existing ? 0 : 1)) }
}
struct PassAccessForm: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: PassManager
    var accessID: UUID? = nil
    @State private var label = ""
    @State private var welcome = ""
    @State private var selected: [String:[Int:KeyObjectAccess]] = [:]
    @State private var editingAccess: PassObjectOption?
    @State private var loaded = false
    @State private var saving = false
    private var record: PassedAccess? { app.passedAccess.first { $0.id == accessID } }
    private var lockedHost: String? {
        record?.server ?? selected.keys.first.flatMap { id in app.guests.first { $0.id == id }?.invite.server }
    }
    private var options: [PassObjectOption] {
        var seen = Set<String>(), result: [PassObjectOption] = []
        for guest in app.guests {
            for object in guest.objects {
                let current = record?.parts.contains { $0.sourceID == guest.id && $0.objects[String(object.numberID)] != nil } == true
                guard let allow = manager.snapshots[guest.id]?.allowance[object.numberID], allow.depth > 0,
                      allow.poolLeft > 0 || current else { continue }
                let key = guest.invite.server + "|" + (object.kind == "ble" ? "b" : "n") + "|" + String(object.numberID)
                if seen.insert(key).inserted { result.append(PassObjectOption(source:guest,object:object,allowance:allow,existing:current)) }
            }
        }
        return result
    }
    private var hosts: [String] { var values: [String] = []; for option in options where !values.contains(option.source.invite.server) { values.append(option.source.invite.server) }; return values }
    private func value(_ option: PassObjectOption) -> KeyObjectAccess { selected[option.source.id]?[option.object.numberID] ?? (try! KeyObjectAccess(nativeOnly:option.allowance.nativeOnly,depth:0,pool:min(3,option.maximumPool))) }
    private func toggle(_ option: PassObjectOption) {
        guard !option.source.paused, lockedHost == nil || lockedHost == option.source.invite.server else { return }
        if selected[option.source.id]?[option.object.numberID] != nil {
            selected[option.source.id]?.removeValue(forKey:option.object.numberID)
            if selected[option.source.id]?.isEmpty == true { selected.removeValue(forKey:option.source.id) }
        } else { selected[option.source.id,default:[:]][option.object.numberID] = value(option) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppField(ProductText.string("guests_name_label")) {
                        TextField(ProductText.string("guests_default_name"),text:$label).textInputAutocapitalization(.words)
                            .onChange(of:label) { value in let normalized=String(value.replacingOccurrences(of:"\n",with:"").replacingOccurrences(of:"\r",with:"").prefix(128));if normalized != value { label=normalized } }
                    }
                    if accessID == nil { AppField(ProductText.string("guests_welcome_label")) { TextField(ProductText.string("guests_welcome_hint"),text:$welcome,axis:.vertical).lineLimit(2...5) } }
                }
                Section { Text(ProductText.string("guests_objects_allowed")).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                ForEach(hosts,id:\.self) { host in
                    Section {
                        ForEach(options.filter { $0.source.invite.server == host }) { option in row(option) }
                    } header: { if hosts.count > 1 { Text(host) } }
                }
                if let message = manager.message { Section { Text(message).font(.footnote).foregroundStyle(Brand.secondaryInk) } }
                if let record, record.parts.contains(where:{ $0.state == .draft }) {
                    Section { Button("Продолжить передачу") { Task { await manager.continueCreating(record.id) } }.buttonStyle(SecondaryActionStyle()).actionListRow() }
                }
                Section {
                    Button { Task { await save() } } label: { ActionButtonLabel(title:ProductText.string(accessID == nil ? "delegate_create" : "btn_save"),busy:saving || manager.busy) }
                        .buttonStyle(PrimaryActionStyle()).actionListRow()
                        .disabled(selected.isEmpty || record?.parts.contains(where:{ $0.pendingEdit != nil || $0.state == .draft }) == true)
                }
            }.disabled(saving || manager.busy || app.busy || app.ownerBusy || !app.canManageGuestAccess)
                .taskSheetTitle(ProductText.string(accessID == nil ? "delegate_create" : "guests_access_title"),form:true)
                .sheetDismissFooter(disabled:saving || manager.busy) { dismiss() }
                .sheet(item:$editingAccess) { option in
                    GuestObjectAccessEditor(title:option.object.label,value:Binding(get:{ value(option) },set:{ selected[option.source.id,default:[:]][option.object.numberID] = $0 }),showNative:false,maxDepth:option.maximumDepth,maxPool:option.maximumPool)
                }
                .task {
                    if !loaded { loaded = true; if let record { label = record.label; for part in record.parts { selected[part.sourceID] = Dictionary(uniqueKeysWithValues:part.objects.compactMap { id,value in Int(id).map { ($0,value) } }) } } }
                    await manager.reload()
                }
        }
    }
    private func row(_ option: PassObjectOption) -> some View {
        let checked = selected[option.source.id]?[option.object.numberID] != nil
        let other = lockedHost != nil && lockedHost != option.source.invite.server
        return HStack(spacing:8) {
            Button { toggle(option) } label: {
                HStack(spacing:12) { Image(systemName:checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? AppPalette.selected : Brand.secondaryInk); Text(option.object.label).frame(maxWidth:.infinity,alignment:.leading) }
                    .foregroundStyle(other ? Brand.secondaryInk : Brand.ink).frame(minHeight:52).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(other || option.source.paused)
                .accessibilityIdentifier("pass-object-" + option.id)
            if checked {
                Button { editingAccess = option } label: { Image(systemName:"person.badge.key").resizable().scaledToFit().frame(width:24,height:24) }
                    .buttonStyle(SquareIconActionStyle()).accessibilityLabel(ProductText.string("guests_access_title"))
            }
        }
    }
    private func save() async {
        guard !saving, !selected.isEmpty else { return }; saving = true; defer { saving = false }
        let name = label.trimmingCharacters(in:.whitespacesAndNewlines)
        if let initial = record {
            let sources = Set(initial.parts.map(\.sourceID)).union(selected.keys)
            for source in sources.sorted() {
                let desired = selected[source] ?? [:]
                let current = app.passedAccess.first(where:{ $0.id == initial.id })?.parts.first(where:{ $0.sourceID == source })?.objects ?? [:]
                let encoded = Dictionary(uniqueKeysWithValues:desired.map { (String($0.key),$0.value) })
                if encoded != current, !(await manager.editObjects(initial.id,sourceID:source,numberIDs:Set(desired.keys),access:desired)) { return }
            }
            guard var latest = app.passedAccess.first(where:{ $0.id == initial.id }) else { return }
            latest.label = name.isEmpty ? ProductText.string("guests_default_name") : name
            do { try app.savePassedAccess(latest) } catch { app.errorMessage = "Не удалось сохранить имя гостя."; return }
            dismiss()
        } else if await manager.create(label:name.isEmpty ? ProductText.string("guests_default_name") : name,welcome:welcome.trimmingCharacters(in:.whitespacesAndNewlines),objects:selected) != nil { dismiss() }
    }
}
struct PassedAccessDetail: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: PassManager
    let accessID: UUID
    @State private var revoking = false
    @State private var composing = false
    @State private var editingSource: String?
    private var record: PassedAccess? { app.passedAccess.first { $0.id == accessID } }
    var body: some View {
        List {
            if let record {
                Section {
                    Text(record.label).font(.headline)
                    Text(passedAccessStatus(record)).foregroundStyle(Brand.secondaryInk)
                    KeyValueRow(title: "Сервер", value: record.server)
                    KeyValueRow(title: "Исходных ключей", value: String(record.parts.count))
                    if let message = manager.message { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                }
                if let link = record.link, let url = URL(string: link.url) {
                    Section {
                        InviteQRCode(text: link.url).frame(maxWidth: .infinity).padding(.vertical, 12)
                        ShareLink(item: url) { Label("Передать ссылку", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryActionStyle())
                        Text(link.url).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                    } footer: { Text("Передавайте ссылку одному получателю. Секрет после # подтверждает, кому вы передаёте доступ.") }
                }
                Section {
                    Button("Обновить данные") { Task { await manager.reload() } }.buttonStyle(SecondaryActionStyle())
                    if record.parts.contains(where: { $0.state == .draft }) {
                        Button("Продолжить передачу") { Task { await manager.continueCreating(record.id) } }.buttonStyle(PrimaryActionStyle())
                    }
                    if record.parts.contains(where: { $0.childID != nil }) && record.link != nil {
                        Button("Написать сообщение") { composing = true }.buttonStyle(SecondaryActionStyle())
                    }
                    ForEach(record.parts.indices, id: \.self) { index in
                        let part = record.parts[index]
                        if ![PassedAccess.State.draft, .revoking, .revoked].contains(part.state) {
                            Button("Изменить объекты · часть \(index + 1)") { editingSource = part.sourceID }.buttonStyle(SecondaryActionStyle()).disabled(part.pendingEdit != nil)
                        }
                    }
                    if !record.parts.allSatisfy({ $0.state == .revoked }) {
                        Button(record.parts.contains(where: { $0.state == .revoking }) ? "Повторить отзыв" : "Отозвать переданный доступ", role: .destructive) { revoking = true }.buttonStyle(SecondaryActionStyle())
                    }
                }.disabled(manager.busy || app.busy || app.ownerBusy)
            }
        }
        .navigationTitle(ProductText.string("guests_key_delegated")).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $composing) { ComposeMessageScreen(manager: app.messages, target: .passed(accessID)) }
        .sheet(isPresented: Binding(get: { editingSource != nil }, set: { if !$0 { editingSource = nil } })) {
            if let source = editingSource { EditPassedObjects(manager: manager, accessID: accessID, sourceID: source) }
        }
        .appConfirmationDialog("Отозвать доступ?",message:"Отозвать весь доступ по этой ссылке и цепочке ниже неё?",actionTitle:"Отозвать доступ",destructive:true,isPresented:$revoking) {
            Task { await manager.revoke(accessID, retry: true) }
        }
    }
}
func passedAccessStatus(_ record: PassedAccess) -> String {
    if record.parts.allSatisfy({ $0.state == .revoked }) { return "Доступ отозван" }
    if record.parts.contains(where: { $0.state == .revoking }) { return "Отзыв не завершён" }
    if record.parts.contains(where: { $0.pendingEdit != nil }) { return "Изменение объектов не подтверждено" }
    if record.parts.contains(where: { $0.state == .draft }) { return "Выдача ссылки не подтверждена" }
    if record.parts.contains(where: { $0.state == .unavailable }) { return "Переданный доступ не подтверждён" }
    if record.parts.contains(where: { $0.state == .awaitingOwner }) { return "Ожидает подтверждения владельцев" }
    if record.parts.allSatisfy({ $0.state == .active }) { return "Доступ действует" }
    return "Ожидает принятия получателем"
}

struct EditPassedObjects: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: PassManager
    let accessID: UUID
    let sourceID: String
    @State private var selected = Set<Int>()
    @State private var loaded = false
    private var record: PassedAccess? { app.passedAccess.first { $0.id == accessID } }
    private var part: PassedAccess.Part? { record?.parts.first { $0.sourceID == sourceID } }
    private var guest: SavedGuest? { app.guests.first { $0.id == sourceID } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Объекты получателя") {
                    ForEach(guest?.objects ?? []) { object in
                        let allow = manager.snapshots[sourceID]?.allowance[object.numberID]
                        let existing = part?.objects[String(object.numberID)] != nil
                        let canAdd = allow?.canPass == true || (existing && (allow?.depth ?? 0) > 0)
                        Button {
                            if selected.contains(object.numberID) { selected.remove(object.numberID) } else { selected.insert(object.numberID) }
                        } label: {
                            HStack { Text(object.label); Spacer(); Image(systemName: selected.contains(object.numberID) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(object.numberID) ? AppPalette.selected : Brand.secondaryInk) }.foregroundStyle(Brand.ink)
                        }.disabled(!selected.contains(object.numberID) && !canAdd)
                    }
                    if guest == nil { Text("Исходный ключ удалён с этого iPhone").foregroundStyle(Brand.secondaryInk) }
                }
                Section {
                    if let message = manager.message { Text(message).foregroundStyle(Brand.secondaryInk) }
                    Button("Сохранить объекты") { Task { if await manager.editObjects(accessID, sourceID: sourceID, numberIDs: selected) { dismiss() } } }.buttonStyle(PrimaryActionStyle()).disabled(guest == nil)
                } footer: { Text("Удаление объекта заберёт его и у тех, кому получатель передал ключ дальше. Пустой набор отзывает эту часть доступа. Добавленные объекты потребуют подтверждения владельца.") }
            }.disabled(manager.busy || app.busy || app.ownerBusy || part?.pendingEdit != nil)
            .taskSheetTitle("Объекты получателя",form:true)
            .sheetDismissFooter(disabled: manager.busy || app.busy || app.ownerBusy) { dismiss() }

            .task { if !loaded { loaded = true; selected = Set(part?.objects.keys.compactMap(Int.init) ?? []) }; await manager.reload(sourceID: sourceID) }
        }
    }
}
