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
            if let notice = manager.message { Section { Text(ProductText.systemMessage(notice)).foregroundStyle(Brand.secondaryInk) } }
            Section(ProductText.string("ios_messages_incoming")) {
                if app.incomingMessages.isEmpty { Text(ProductText.string("ios_messages_empty")).foregroundStyle(Brand.secondaryInk) }
                ForEach(app.incomingMessages) { row in
                    NavigationLink { ReadMessageScreen(manager: manager, messageID: row.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(row.readAt == nil ? ProductText.string("ios_message_new") : ProductText.string("ios_message_by_key")).font(.headline)
                                Spacer()
                                Text(ProductText.date(row.receivedAt)).font(.caption).foregroundStyle(Brand.secondaryInk)
                            }
                            Text((try? manager.text(row)) ?? ProductText.string("ios_message_decrypt_failed")).lineLimit(2).foregroundStyle(Brand.secondaryInk)
                        }.padding(.vertical, 5)
                    }
                }
            }
            if !app.outgoingMessages.isEmpty {
                Section(ProductText.string("ios_messages_outgoing")) {
                    ForEach(app.outgoingMessages) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.text).foregroundStyle(Brand.ink)
                            Text(outgoingMessageStatus(row)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                            Text(ProductText.date(row.created)).font(.caption).foregroundStyle(Brand.secondaryInk)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }
        .navigationTitle(ProductText.string("ios_messages")).navigationBarTitleDisplayMode(.inline)
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
                    Text(ProductText.string("ios_message_by_key")).font(.headline)
                    Text(ProductText.date(saved.receivedAt)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    if let guest = app.guests.first(where: { $0.id == saved.guestID }) { KeyValueRow(title: ProductText.string("ble_server_label"), value: guest.invite.server) }
                    if let text = try? manager.text(saved) { Text(text).textSelection(.enabled) }
                    else { Text(ProductText.string("ios_message_decrypt_failed")).foregroundStyle(Brand.secondaryInk) }
                }
                if let notice = manager.message { Section { Text(ProductText.systemMessage(notice)).foregroundStyle(Brand.secondaryInk) } }
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
                    Text(ProductText.string("ios_message_recipient")).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    AppField(ProductText.string("ios_message_text")) {
                        TextField(ProductText.string("ios_message_text"), text: $text, axis: .vertical).lineLimit(3...6)
                            .accessibilityIdentifier("message-text")
                    }
                    Text("\(text.count) / 500").font(.caption).foregroundStyle(Brand.secondaryInk)
                    if let notice = manager.message { Text(ProductText.systemMessage(notice)).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    Button {
                        Task {
                            let previous = Set(app.outgoingMessages.map(\.id))
                            let sent = await manager.send(text, target: target)
                            sentID = app.outgoingMessages.first(where: { !previous.contains($0.id) })?.id
                            if sent { text = "" }
                        }
                    } label: { ActionButtonLabel(title: ProductText.string("msg_send_icon_desc"), busy: manager.busy) }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 500 || text.utf8.count > 2048)
                        .accessibilityIdentifier("message-send")
                } footer: { Text(ProductText.string("ios_message_delivery_hint")) }
            }.disabled(manager.busy)
            .taskSheetTitle(ProductText.string("ios_message_compose"),form:true)
            .sheetDismissFooter(sentID == nil ? ProductText.string("btn_cancel") : ProductText.string("btn_close"), disabled: manager.busy) { dismiss() }

        }
    }
}
func outgoingMessageStatus(_ row: OutgoingMessage) -> String {
    switch row.state {
    case .accepted: return ProductText.string("ios_message_accepted")
    case .sending, .uncertain: return ProductText.string("ios_message_unconfirmed")
    }
}
