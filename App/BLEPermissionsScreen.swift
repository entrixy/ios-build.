import SwiftUI
import EntrixyCore

struct BLEPermissionsScreen: View {
    @EnvironmentObject private var app: AppModel
    let server: String
    let deviceID: UInt32
    var body: some View { BLEPermissionsContent(model: app.bleControl, server: server, deviceID: deviceID) }
}

private struct BLEPermissionsContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BLEOwnerControlModel
    let server: String
    let deviceID: UInt32
    private var owner: OwnerAccount? { app.owners.first { $0.server == server } }
    private var records: [BLERevocation] { (owner?.bleRevocations ?? []).filter { $0.deviceID == deviceID }.sorted { $0.version > $1.version } }
    var body: some View {
        List {
            Section {
                Button("Передать настройки контроллеру") { Task { await model.deliverDecisions(server: server, deviceID: deviceID) } }.buttonStyle(PrimaryActionStyle())
                    .disabled(model.busy || app.ownerBusy || records.isEmpty)
                if model.busy { ProgressView("Передача по Bluetooth…") }
                if let text = model.deliveryMessages[deviceID] { Text(text).foregroundStyle(Brand.secondaryInk) }
            } footer: {
                Text("Поднесите iPhone к контроллеру и разбудите его. Пока контроллер не получил отзыв, ранее выданный офлайн-пропуск может действовать до истечения срока.")
            }
            if records.isEmpty { Text("Нет сохранённых изменений доступа").foregroundStyle(Brand.secondaryInk) }
            ForEach(records) { record in
                Section {
                    Text(guestLabel(record)).font(.headline)
                    Text(record.revoked ? "Решение владельца: запретить доступ" : "Решение владельца: разрешить доступ")
                    Text(status(record)).foregroundStyle(Brand.secondaryInk)
                    if record.controllerResult == 0x41 {
                        Button("Подготовить новую версию решения") { Task { await app.refreshOwnerBLEDecision(server: server, record: record) } }.buttonStyle(SecondaryActionStyle())
                            .disabled(model.busy || app.ownerBusy)
                    }
                }
            }
        }
        .navigationTitle("Bluetooth-доступ").navigationBarTitleDisplayMode(.inline)
    }
    private func guestLabel(_ record: BLERevocation) -> String {
        owner?.issuedKeys?.first(where: { $0.guestID == Int(record.guestID) })?.label
            ?? owner?.delegatedKeys?.first(where: { $0.guestID == Int(record.guestID) })?.label
            ?? "Гостевой пропуск"
    }
    private func status(_ record: BLERevocation) -> String {
        if record.applied { return "Контроллер подтвердил применение" }
        if record.controllerResult == 0x41 { return "Контроллеру известно это или более новое решение. Точное состояние не подтверждено." }
        return "Ожидает передачи контроллеру"
    }
}
