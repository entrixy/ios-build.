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
            let objectLabel = app.objectLabel(.owned(owner,object))
            AppDialogSurface {
                VStack(alignment: .leading, spacing: 18) {
                    Text(ProductText.string("confirm_title")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    HStack(alignment:.top,spacing:16) {
                        CatalogAvatar(entry:.owned(owner,object),size:64)
                            .accessibilityElement(children:.ignore).accessibilityAddTraits(.isImage)
                            .accessibilityLabel(objectLabel).accessibilityIdentifier("owner-phone-object-image")
                        Text(ProductText.string("ios_guest_open_request",key.label,objectLabel))
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .accessibilityIdentifier("owner-phone-request-description")
                    }
                    if object.kind == "call" {
                        Text(ProductText.string("ios_call_question")).font(.headline)
                    }

                }
            } footer: {
                    EqualActionRow {
                        Button(ProductText.string("confirm_decline"), role: .destructive) { Task { await control.decline(request) } }
                            .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("owner-phone-decline")
                        Button {
                            approving = true
                            Task { await control.approve(request); approving = false }
                        } label: { ActionButtonLabel(title: ProductText.string(object.kind == "call" ? "ios_call_now" : "confirm_allow"), busy: approving) }
                            .buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("owner-phone-approve")
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
