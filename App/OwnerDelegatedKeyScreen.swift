import SwiftUI
import EntrixyCore

struct OwnerDelegatedKeyScreen: View {
    @EnvironmentObject private var app: AppModel
    let server: String
    let keyID: UUID
    @State private var revoking = false
    @State private var retrying = false
    private var owner: OwnerAccount? { app.owners.first { $0.server == server } }
    private var key: OwnerDelegatedKey? { owner?.delegatedKeys?.first { $0.id == keyID } }
    var body: some View {
        List {
            if let key {
                Section {
                    Text(key.label).font(.headline)
                    if let message = app.ownerMessages[server] { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    Text(ownerDelegatedStatus(key)).foregroundStyle(Brand.secondaryInk)
                    if let message = app.ownerDelegationMessages[keyID] { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    KeyValueRow(title: "Сервер", value: server)
                }
                Section("Объекты") {
                    ForEach(key.numberIDs, id: \.self) { id in
                        Text(objectLabel(id))
                    }
                }
                Section {
                    Button("Обновить данные") { Task { await app.refreshOwners() } }.disabled(app.ownerBusy)
                    if key.state == .awaiting && key.revocationPending != true {
                        if key.sent {
                            Button("Повторить передачу связки") { retrying = true }.disabled(app.ownerBusy)
                        } else {
                            Button("Подтвердить переданный доступ") { Task { await app.approveDelegatedKey(server: server, keyID: keyID) } }.disabled(app.ownerBusy)
                        }
                    }
                    if key.state != .revoked && key.revocationSent != true {
                        Button("Отозвать доступ", role: .destructive) { revoking = true }.disabled(app.ownerBusy)
                    }
                } footer: { Text("Получатель использует собственный ключ. Связка выдаётся только после проверки поручительства и прав передавшего. Передача связки сама по себе не открывает объект.") }
            } else { Text("Переданный ключ недоступен").foregroundStyle(Brand.secondaryInk) }
        }
        .navigationTitle("Переданный доступ").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Отозвать доступ у этого получателя и всей цепочки ниже него?", isPresented: $revoking, titleVisibility: .visible) {
            Button("Отозвать доступ", role: .destructive) { Task { await app.revokeDelegatedKey(server: server, keyID: keyID) } }
        }
        .confirmationDialog("Передать ту же сохранённую связку повторно? Команда открытия не отправляется.", isPresented: $retrying, titleVisibility: .visible) {
            Button("Передать связку") { Task { await app.approveDelegatedKey(server: server, keyID: keyID, retry: true) } }
        }
    }
    private func objectLabel(_ id: Int) -> String {
        guard let owner, let object = owner.objects?.first(where: { $0.numberID == id }) else { return "Объект \(id)" }
        return (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Объект \(id)"
    }
}
func ownerDelegatedStatus(_ key: OwnerDelegatedKey) -> String {
    if key.revocationPending == true { return "Отзыв ожидает подтверждения сервера" }
    switch key.state {
    case .awaiting: return key.sent ? "Связка ожидает подтверждения сервера" : "Поручительство проверено, требуется связка"
    case .ready: return "Доступ действует"
    case .unavailable: return "Доступ не подтверждён или цепочка приостановлена"
    case .revoked: return "Доступ отозван"
    }
}
