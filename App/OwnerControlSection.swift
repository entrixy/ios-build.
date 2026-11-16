import SwiftUI
import EntrixyCore

struct OwnerPhoneRequestRows: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var control: OwnerControlModel
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
    }
}

struct OwnerCatalogControlCard: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var control: OwnerControlModel
    @ObservedObject var ble: BLEOwnerControlModel
    let owner: OwnerAccount
    let object: OwnerObject
    @State private var selected: OwnerActionIntent?
    private var entry: CatalogObject { .owned(owner, object) }
    var body: some View {
        Button {
            guard let intent = app.ownerActionIntent(server: owner.server, objectID: object.id) else { return }
            if intent.policy.confirmation || intent.policy.authentication != nil { selected = intent }
            else { Task { await app.execute(intent) } }
        } label: {
            HStack(spacing: 16) {
                CatalogStatusAvatar(entry: entry, control: control)
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.objectLabel(entry)).font(.headline).foregroundStyle(.primary)
                    ObjectSourceLabel(entry: entry)
                    if let rejection = app.ownerActionRejections[object.id] {
                        Text(rejection.message).font(.subheadline).foregroundStyle(.red)
                    }
                    if let message = ble.messages[object.id] { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    if let message = control.messages[object.id] { Text(message).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(CardActionStyle())
            .modifier(ActionRejectionFeedback(rejection: app.ownerActionRejections[object.id]))
            .accessibilityLabel(app.objectLabel(entry) + ". Управлять")
            .sheet(item: $selected) { ActionConfirmation(ownerIntent: $0) }
    }
}
