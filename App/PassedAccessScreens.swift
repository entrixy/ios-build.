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
struct PassAccessForm: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: PassManager
    @State private var server = ""
    @State private var label = ""
    @State private var welcome = ""
    @State private var selected: [String: [Int: KeyObjectAccess]] = [:]
    private var servers: [String] { Array(Set(app.guests.map { $0.invite.server })).sorted() }
    private func settings(_ source: String, _ number: Int) -> KeyObjectAccess { selected[source]?[number] ?? (try! KeyObjectAccess(depth: 0, pool: 1)) }
    private func change(_ source: String, _ number: Int, depth: Int? = nil, pool: Int? = nil) {
        if let value = try? KeyObjectAccess(depth: depth ?? settings(source, number).depth, pool: pool ?? settings(source, number).pool) { selected[source, default: [:]][number] = value }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Сервер", selection: $server) { ForEach(servers, id: \.self) { Text($0).tag($0) } }
                    AppField("Имя получателя") {
                        TextField("Имя получателя", text: $label)
                    }
                    AppField("Приветствие") {
                        TextField("Приветствие", text: $welcome, axis: .vertical)
                    }
                }
                ForEach(Array(app.guests.filter { $0.invite.server == server }.enumerated()), id: \.element.id) { index, guest in
                    Section("Полученный ключ \(index + 1)") {
                        ForEach(guest.objects.filter { $0.kind != "ble" }) { object in
                            if let allow = manager.snapshots[guest.id]?.allowance[object.numberID], allow.canPass {
                                let chosen = selected[guest.id]?[object.numberID] != nil
                                Button {
                                    if chosen { selected[guest.id]?.removeValue(forKey: object.numberID); if selected[guest.id]?.isEmpty == true { selected.removeValue(forKey: guest.id) } }
                                    else { change(guest.id, object.numberID) }
                                } label: {
                                    HStack { Text(object.label); Spacer(); Image(systemName: chosen ? "checkmark.circle.fill" : "circle") }.foregroundStyle(Brand.ink)
                                }.disabled(guest.paused)
                                if chosen {
                                    Stepper("Уровней ниже получателя: \(settings(guest.id, object.numberID).depth)", value: Binding(get: { settings(guest.id, object.numberID).depth }, set: { change(guest.id, object.numberID, depth: $0) }), in: 0...max(0, allow.depth - 1))
                                    if settings(guest.id, object.numberID).depth > 0 {
                                        Stepper("Ключей ниже по цепочке: \(settings(guest.id, object.numberID).pool)", value: Binding(get: { settings(guest.id, object.numberID).pool }, set: { change(guest.id, object.numberID, pool: $0) }), in: 1...max(1, allow.poolLeft - 1))
                                    }
                                }
                            }
                        }
                        if guest.paused { Text("Исходный ключ приостановлен").foregroundStyle(Brand.secondaryInk) }
                    }
                }
                Section {
                    Button("Обновить права передачи") { Task { await manager.reload() } }.buttonStyle(SecondaryActionStyle())
                    if let message = manager.message { Text(message).foregroundStyle(Brand.secondaryInk) }
                    Button {
                        Task { if await manager.create(label: label, welcome: welcome, objects: selected) != nil { dismiss() } }
                    } label: { ActionButtonLabel(title: "Создать ссылку передачи", busy: manager.busy) }.buttonStyle(PrimaryActionStyle())
                        .disabled(selected.isEmpty || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: { Text("Доступны только объекты, которые владелец разрешил передавать. Получатель создаст собственный ключ; владельцы подтвердят его связку.") }
            }
            .disabled(manager.busy || app.busy || app.ownerBusy)
            .navigationTitle("Передать доступ").navigationBarTitleDisplayMode(.inline)
            .sheetDismissFooter(disabled: manager.busy || app.busy || app.ownerBusy) { dismiss() }

            .task { if server.isEmpty { server = servers.first ?? "" }; await manager.reload() }
            .onChange(of: server) { _ in selected = [:] }
        }
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
        .navigationTitle("Переданный ключ").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $composing) { ComposeMessageScreen(manager: app.messages, target: .passed(accessID)) }
        .sheet(isPresented: Binding(get: { editingSource != nil }, set: { if !$0 { editingSource = nil } })) {
            if let source = editingSource { EditPassedObjects(manager: manager, accessID: accessID, sourceID: source) }
        }
        .confirmationDialog("Отозвать весь доступ по этой ссылке и цепочке ниже неё?", isPresented: $revoking, titleVisibility: .visible) {
            Button("Отозвать доступ", role: .destructive) { Task { await manager.revoke(accessID, retry: true) } }
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
                    ForEach(guest?.objects.filter { $0.kind != "ble" } ?? []) { object in
                        let allow = manager.snapshots[sourceID]?.allowance[object.numberID]
                        let existing = part?.objects[String(object.numberID)] != nil
                        let canAdd = allow?.canPass == true || (existing && (allow?.depth ?? 0) > 0 && allow?.nativeOnly == false)
                        Button {
                            if selected.contains(object.numberID) { selected.remove(object.numberID) } else { selected.insert(object.numberID) }
                        } label: {
                            HStack { Text(object.label); Spacer(); Image(systemName: selected.contains(object.numberID) ? "checkmark.circle.fill" : "circle") }.foregroundStyle(Brand.ink)
                        }.disabled(!selected.contains(object.numberID) && !canAdd)
                    }
                    if guest == nil { Text("Исходный ключ удалён с этого iPhone").foregroundStyle(Brand.secondaryInk) }
                }
                Section {
                    if let message = manager.message { Text(message).foregroundStyle(Brand.secondaryInk) }
                    Button("Сохранить объекты") { Task { if await manager.editObjects(accessID, sourceID: sourceID, numberIDs: selected) { dismiss() } } }.buttonStyle(PrimaryActionStyle()).disabled(guest == nil)
                } footer: { Text("Удаление объекта заберёт его и у тех, кому получатель передал ключ дальше. Пустой набор отзывает эту часть доступа. Добавленные объекты потребуют подтверждения владельца.") }
            }.disabled(manager.busy || app.busy || app.ownerBusy || part?.pendingEdit != nil)
            .navigationTitle("Объекты получателя").navigationBarTitleDisplayMode(.inline)
            .sheetDismissFooter(disabled: manager.busy || app.busy || app.ownerBusy) { dismiss() }

            .task { if !loaded { loaded = true; selected = Set(part?.objects.keys.compactMap(Int.init) ?? []) }; await manager.reload(sourceID: sourceID) }
        }
    }
}
