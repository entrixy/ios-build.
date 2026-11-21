import SwiftUI
import EntrixyCore

struct BLEPairingScreen: View {
    @EnvironmentObject private var app: AppModel
    let server: String
    var initialLabel = ""
    var manager: BLEPairingModel? = nil
    var completion: ((ObjectReference?) -> Void)? = nil
    var body: some View { BLEPairingContent(model: manager ?? app.blePairing, server: server, label: initialLabel, completion: completion).environmentObject(app) }
}

private struct BLEPairingContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BLEPairingModel
    let server: String
    @State private var label: String
    let completion: ((ObjectReference?) -> Void)?
    init(model: BLEPairingModel, server: String, label: String = "", completion: ((ObjectReference?) -> Void)? = nil) {
        self.model = model; self.server = server; self.completion = completion; _label = State(initialValue: label)
    }
    @State private var selected: BLEDiscovery?
    private var records: [BLEPairingRecord] { app.owners.first(where: { $0.server == server })?.blePairings ?? [] }
    var body: some View {
        Form {
            Section {
                AppField("Название объекта") {
                    TextField("Название объекта", text: $label)
                }
                Text("Включите режим привязки на своём контроллере и держите iPhone рядом. Привязка меняет ключ владельца контроллера.")
                    .font(.footnote).foregroundStyle(Brand.secondaryInk)
                Button("Найти контроллеры") { Task { await model.scan() } }.buttonStyle(PrimaryActionStyle()).disabled(model.busy)
                ForEach(model.discoveries) { discovery in
                    Button { selected = discovery } label: {
                        HStack {
                            Text(discovery.name).foregroundStyle(Brand.ink)
                            Spacer()
                            Text("\(discovery.rssi) dBm").foregroundStyle(Brand.secondaryInk)
                        }
                    }.buttonStyle(SecondaryActionStyle()).disabled(model.busy || app.ownerBusy || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || records.contains(where: { $0.peripheralID == discovery.id }))
                }
            } header: { Text("Новая привязка") }
            if model.busy { Section { ProgressView("Bluetooth…") } }
            if let message = model.message { Section { Text(message).foregroundStyle(Brand.secondaryInk) } }
            ForEach(records) { record in
                Section {
                    Text(record.label).font(.headline)
                    Text(status(record)).foregroundStyle(Brand.secondaryInk)
                    if record.phase == .confirmed {
                        NavigationLink("Bluetooth-доступ гостей") { BLEPermissionsScreen(server: server, deviceID: record.deviceID) }
                    }
                    if record.phase == .prepared {
                        Button("Отправить сохранённую привязку") { Task { await model.sendPrepared(pairingID: record.id, server: server) } }.buttonStyle(PrimaryActionStyle()).disabled(model.busy || app.ownerBusy)
                    }
                    if record.objectID == nil, record.phase != .prepared {
                        Button("Проверить привязку") { Task { await model.check(pairingID: record.id, server: server) } }.buttonStyle(SecondaryActionStyle()).disabled(model.busy || app.ownerBusy)
                    }
                    if record.phase == .confirmed, record.objectID == nil {
                        Button("Добавить на сервер") {
                            Task {
                                _ = await app.registerPairedBLE(server: server, pairingID: record.id)
                                // Complete only this pairing's durable object, including an
                                // uncertain registration; never select an unrelated saved peer.
                                if let id = records.first(where: { $0.id == record.id })?.objectID {
                                    completion?(.owned(server: server, objectID: id))
                                }
                            }
                        }.buttonStyle(PrimaryActionStyle())
                            .disabled(model.busy || app.ownerBusy)
                    }
                } header: { Text("Сохранённая привязка") }
            }
        }
        .navigationTitle("Bluetooth-контроллер").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible,for:.navigationBar)
        .onDisappear { if model.busy { model.suspend() } }
        .appConfirmationDialog("Привязать свой контроллер?",message:"Убедитесь, что выбран ваш контроллер в режиме привязки. Его название не является проверкой подлинности.",actionTitle:"Привязать",isPresented:Binding(get:{ selected != nil },set:{ if !$0 { selected = nil } })) {
            if let selected { let id = selected.id; self.selected = nil
                Task { await model.pair(discoveryID:id,server:server,label:label) }
            }
        }
    }
    private func status(_ record: BLEPairingRecord) -> String {
        if record.objectID != nil { return "Объект сохранён. Состояние добавления — в списке «Мои объекты»." }
        switch record.phase {
        case .prepared: return "Секрет сохранён; отправка не начиналась. Можно отправить сохранённую привязку; новый ключ не создаётся."
        case .sent: return "Исход записи неизвестен. Проверьте подпись контроллера поиском."
        case .confirmed: return "Привязка подтверждена подписью контроллера."
        }
    }
}
