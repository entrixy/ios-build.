import SwiftUI
import EntrixyCore

struct DelegationInboxScreen: View {
    @EnvironmentObject private var app: AppModel
    var manager: DelegationInbox? = nil
    var body: some View { DelegationInboxContent(manager: manager ?? app.delegationInbox) }
}
private struct DelegationInboxContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: DelegationInbox
    @State private var removing: String?
    var body: some View {
        List {
            if let message = manager.message { Section { Text(message).foregroundStyle(Brand.secondaryInk) } }
            if app.delegations.isEmpty { Text("Нет ожидаемых ключей").foregroundStyle(Brand.secondaryInk) }
            if !app.receivedDelegations.isEmpty {
                Section("Принятые передачи") {
                    ForEach(app.receivedDelegations) { receipt in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(receipt.link.server).font(.headline)
                            Text("Установлено частей: \(receipt.parts.count)").foregroundStyle(Brand.secondaryInk)
                        }
                    }
                    Button("Проверить новые части") {
                        Task { await manager.refreshAdditionalParts(); await manager.checkAll() }
                    }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                }
            }
            ForEach(app.delegations) { pending in
                Section {
                    KeyValueRow(title: "Сервер", value: pending.link.server)
                    KeyValueRow(title: "Ожидают подтверждения", value: String(pending.parts.count - pending.completedCodes.count))
                    if !pending.sent {
                        Button("Отправить принятие") { Task { await manager.send(pending.id) } }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                    }
                    Button("Проверить подтверждение") { Task { await manager.check(pending.id) } }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                    Button("Удалить ожидание с iPhone", role: .destructive) { removing = pending.id }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || app.busy || app.ownerBusy)
                } footer: { Text("Подтверждение требует участия передавшего и владельца объектов. Данные получателя сохранены; повторный запрос принятия не выполняется.") }
            }
        }
        .navigationTitle("Ожидаемые ключи").navigationBarTitleDisplayMode(.inline)
        .appConfirmationDialog("Удалить данные получателя?",message:"Ключи этой передачи могут стать невосстановимыми: потребуется новый доступ от владельца.",actionTitle:"Удалить с iPhone",destructive:true,isPresented:Binding(get:{ removing != nil },set:{ if !$0 { removing = nil } })) {
            if let id = removing { app.removePendingDelegation(id) }; removing = nil
        }
    }
}

struct DelegationImportSection: View {
    @ObservedObject var manager: DelegationInbox
    let input: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = manager.message { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
            if let pending = manager.preview {
                Text("Переданный доступ").font(.headline)
                KeyValueRow(title: "Сервер", value: pending.link.server)
                KeyValueRow(title: "Частей ключа", value: String(pending.parts.count))
                Text("На этом iPhone будут созданы собственные ключи. Доступ станет доступен после подтверждения передавшим и владельцами объектов.").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                Button("Принять передачу") { Task { await manager.accept() } }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy)
            } else {
                Button { Task { await manager.inspect(input) } } label: {
                    HStack { if manager.busy { ProgressView() }; Text("Проверить переданный доступ") }
                }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy)
            }
        }
        .onChange(of: input) { _ in manager.clearPreview() }
        .onDisappear { manager.clearPreview() }
    }
}
