import SwiftUI
import EntrixyCore

private struct OwnerTap: Identifiable {
    let server: String
    let object: OwnerObject
    let label: String
    var id: UUID { object.id }
}

struct OwnerControlSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var control: OwnerControlModel
    let query: String
    @State private var selected: OwnerTap?
    @ObservedObject var ble: BLEOwnerControlModel
    init(control: OwnerControlModel, query: String, ble: BLEOwnerControlModel) { self.control = control; self.query = query; self.ble = ble }

    var body: some View {
        ForEach(control.phoneRequests) { request in
            if let owner = app.owners.first(where: { $0.server == request.server }),
               let object = owner.objects?.first(where: { $0.id == request.objectID }),
               let key = owner.issuedKeys?.first(where: { $0.id == request.keyID }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Запрос гостя").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    Text(key.label).font(.headline)
                    Text((try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Объект")
                    Text("iPhone запросит подтверждение телефонного звонка.").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    HStack {
                        Button("Позвонить") { Task { await control.dial(server: request.server, objectID: object.id, request: request) } }
                            .buttonStyle(PrimaryActionStyle())
                        Button("Отказать", role: .destructive) { Task { await control.decline(request) } }.buttonStyle(SecondaryActionStyle())
                    }
                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 22))
            }
        }
        ForEach(app.owners) { owner in
            ForEach((owner.objects ?? []).filter(\.ownerCardAvailable)) { object in
                let label = (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Название недоступно"
                if query.isEmpty || label.localizedCaseInsensitiveContains(query) {
                    Button { selected = OwnerTap(server: owner.server, object: object, label: label) } label: {
                        HStack(spacing: 16) {
                            Image("object-3").resizable().scaledToFit().frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(label).font(.headline).foregroundStyle(.primary)
                                Text(object.kind == "ble" ? "Bluetooth · импульс / переключение" : object.kind == "call" ? "Звонок с подтверждением iPhone"
                                     : (object.kind == "device" && object.wrappedSocketSecret == nil ? "Нужна защищённая настройка контроллера"
                                        : (control.connections[owner.server] ?? .offline).title))
                                    .font(.subheadline).foregroundStyle(Brand.secondaryInk)
                                if let message = ble.messages[object.id] { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                                if let message = control.messages[object.id] { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                                ActionCardAffordance(title: "Выбрать действие").padding(.top, 6)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(CardActionStyle())
                }
            }
        }
        .confirmationDialog(selected?.label ?? "Управление объектом", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let item = selected {
                if item.object.kind == "ble" {
                    Button("Подать импульс / переключить") { Task { await ble.execute(server: item.server, objectID: item.id) } }.disabled(ble.busy)
                } else if item.object.kind == "call" {
                    Button("Позвонить") { Task { await control.dial(server: item.server, objectID: item.id) } }
                } else {
                    Button("Открыть") { Task { await control.execute(server: item.server, objectID: item.id, action: .open) } }
                    if item.object.kind == "device" {
                        Button("Закрыть") { Task { await control.execute(server: item.server, objectID: item.id, action: .close) } }
                    }
                }
                Button("Отмена", role: .cancel) { selected = nil }
            }
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if [ActionCaptureScenario.ownerConfirm, .bleOwnerConfirm].contains(ActionCaptureScenario.current ?? .control),
               let owner = app.owners.first, let object = owner.objects?.first {
                selected = OwnerTap(server: owner.server, object: object,
                                    label: (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Объект")
            }
            #endif
        }
    }
}
