import SwiftUI
import EntrixyCore

/// MainActivity.ConfirmDialog: one compact request over the current tab.
struct OwnerPhoneRequestDialog: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var control: OwnerControlModel
    @State private var approving = false
    var body: some View {
        if let request = control.phoneRequests.first,
           let owner = app.owners.first(where: { $0.server == request.server }),
           let object = owner.objects?.first(where: { $0.id == request.objectID }),
           let key = try? owner.authorizedGuest(localID: request.keyID, numberID: object.numberID ?? 0) {
            AppDialogSurface {
                VStack(alignment: .leading, spacing: 18) {
                    Text(ProductText.string("confirm_title")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Text(ProductText.string("confirm_text_intro", key.label))
                    Text((try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Объект").font(.headline)
                    if object.kind == "call" {
                        Text("iPhone запросит подтверждение телефонного звонка.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }

                }
            } footer: {
                    HStack(spacing: 12) {
                        Button(ProductText.string("confirm_decline"), role: .destructive) { Task { await control.decline(request) } }
                            .buttonStyle(SecondaryActionStyle())
                        Button {
                            approving = true
                            Task { await control.approve(request); approving = false }
                        } label: { ActionButtonLabel(title: ProductText.string("confirm_allow"), busy: approving) }
                            .buttonStyle(PrimaryActionStyle())
                    }.disabled(approving)
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
    private var entry: CatalogObject { .owned(owner, object) }
    var body: some View {
        ObjectControlCard(automation:app.automation,entry:entry,accessibilityText:app.objectLabel(entry)+". Управлять",action:{
            guard let intent = app.ownerActionIntent(server: owner.server, objectID: object.id) else { return false }
            if intent.policy.confirmation || intent.policy.authentication != nil { app.actionPrompt = .owner(intent) }
            else { Task { await app.execute(intent) } }
            return true
        }) {
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
            }
        }
            .modifier(ActionRejectionFeedback(rejection: app.ownerActionRejections[object.id]))
    }
}
