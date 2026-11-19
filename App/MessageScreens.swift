import SwiftUI

struct MessagesScreen: View {
    @EnvironmentObject private var app: AppModel
    var manager: MessageManager? = nil
    var body: some View { MessageListContent(manager: manager ?? app.messages) }
}
private struct MessageListContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: MessageManager
    var body: some View {
        List {
            if let notice = manager.message { Section { Text(notice).foregroundStyle(Brand.secondaryInk) } }
            Section("Входящие") {
                if app.incomingMessages.isEmpty { Text("Сообщений пока нет").foregroundStyle(Brand.secondaryInk) }
                ForEach(app.incomingMessages) { row in
                    NavigationLink { ReadMessageScreen(manager: manager, messageID: row.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(row.readAt == nil ? "Новое сообщение" : "Сообщение по ключу").font(.headline)
                                Spacer()
                                Text(row.receivedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Brand.secondaryInk)
                            }
                            Text((try? manager.text(row)) ?? "Не удалось расшифровать сообщение").lineLimit(2).foregroundStyle(Brand.secondaryInk)
                        }.padding(.vertical, 5)
                    }
                }
            }
            if !app.outgoingMessages.isEmpty {
                Section("Исходящие") {
                    ForEach(app.outgoingMessages) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.text).foregroundStyle(Brand.ink)
                            Text(outgoingMessageStatus(row)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            Text(row.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Brand.secondaryInk)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }
        .navigationTitle("Сообщения").navigationBarTitleDisplayMode(.inline)
        .task { await manager.retryAcknowledgements() }
    }
}
struct ReadMessageScreen: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: MessageManager
    let messageID: String
    private var saved: SavedMessage? { app.incomingMessages.first { $0.id == messageID } }
    var body: some View {
        List {
            if let saved {
                Section {
                    Text("Сообщение по ключу").font(.headline)
                    Text(saved.receivedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    if let guest = app.guests.first(where: { $0.id == saved.guestID }) { KeyValueRow(title: "Сервер", value: guest.invite.server) }
                    if let text = try? manager.text(saved) { Text(text).textSelection(.enabled) }
                    else { Text("Не удалось расшифровать сообщение").foregroundStyle(Brand.secondaryInk) }
                }
                if let notice = manager.message { Section { Text(notice).foregroundStyle(Brand.secondaryInk) } }
            }
        }
        .navigationTitle(ProductText.string("msg_incoming_title")).navigationBarTitleDisplayMode(.inline)
        .task { await manager.read(messageID) }
    }
}
struct ComposeMessageScreen: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: MessageManager
    let target: MessageTarget
    @State private var text = ""
    @State private var sentID: UUID?
    private var latest: OutgoingMessage? { app.outgoingMessages.first { $0.id == sentID } }
    var body: some View {
        NavigationStack {
            Form {
                if let latest {
                    Section {
                        Text(latest.text)
                        Text(outgoingMessageStatus(latest)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    }
                }
                Section {
                    AppField("Текст сообщения") {
                        TextField("Текст сообщения", text: $text, axis: .vertical).lineLimit(3...6)
                            .accessibilityIdentifier("message-text")
                    }
                    Text("\(text.count) / 500").font(.caption).foregroundStyle(Brand.secondaryInk)
                    if let notice = manager.message { Text(notice).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    Button {
                        Task {
                            let previous = Set(app.outgoingMessages.map(\.id))
                            let sent = await manager.send(text, target: target)
                            sentID = app.outgoingMessages.first(where: { !previous.contains($0.id) })?.id
                            if sent { text = "" }
                        }
                    } label: { ActionButtonLabel(title: "Отправить сообщение", busy: manager.busy) }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 500 || text.utf8.count > 2048)
                        .accessibilityIdentifier("message-send")
                } header: { Text("Сообщение получателю") } footer: { Text("Отправка на сервер ещё не подтверждает доставку или чтение получателем.") }
            }.disabled(manager.busy)
            .navigationTitle("Написать сообщение").navigationBarTitleDisplayMode(.inline)
            .sheetDismissFooter(sentID == nil ? "Отмена" : "Закрыть", disabled: manager.busy) { dismiss() }

        }
    }
}
func outgoingMessageStatus(_ row: OutgoingMessage) -> String {
    switch row.state {
    case .accepted: return "Принято сервером"
    case .sending, .uncertain: return "Отправка не подтверждена"
    }
}
