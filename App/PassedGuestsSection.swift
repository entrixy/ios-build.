import SwiftUI
import EntrixyCore

/// PassOnSection.kt lives below the owner's tabs, rather than a separate list
/// reached by an invented navigation row.
struct PassedGuestsSection: View {
    @EnvironmentObject private var app: AppModel
    let otherSection: Bool
    var body: some View { PassedGuestsContent(manager:app.passManager,otherSection:otherSection) }
}
private struct PassedGuestsContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: PassManager
    let otherSection: Bool
    @State private var adding = false
    @State private var editing: PassedAccess?
    @State private var messaging: PassedAccess?
    private var visible: [PassedAccess] { app.passedAccess.filter { !$0.parts.allSatisfy({ $0.state == .revoked }) } }
    private var canPass: Bool {
        app.guests.contains { guest in !guest.paused && (guest.incomingDepth ?? 0) > 0 && manager.snapshots[guest.id]?.allowance.values.contains(where:{ $0.canPass }) == true }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if otherSection, !visible.isEmpty { Text(ProductText.string("delegate_create")).font(.headline).padding(.top,12) }
            ForEach(visible) { record in
                PassedGuestCard(record:record,edit:{ editing = record },message:{ messaging = record },remove:{ app.guestRemovalTarget = .passed(record) })
                    .disabled(manager.busy || app.ownerBusy || app.busy || !app.canManageGuestAccess)
            }
            if let message = manager.message { Text(ProductText.systemMessage(message)).font(.footnote).foregroundStyle(Brand.secondaryInk) }
            if canPass {
                Button { adding = true } label: { Label(ProductText.string("delegate_create"),systemImage:"plus") }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy || app.ownerBusy || app.busy)
                    .accessibilityIdentifier("pass-received-access")
            }
        }.task { await manager.reload() }
            .sheet(isPresented:$adding) { PassAccessForm(manager:manager) }
            .sheet(item:$editing) { PassedObjectsEditor(manager:manager,accessID:$0.id) }
            .sheet(item:$messaging) { ComposeMessageScreen(manager:app.messages,target:.passed($0.id)) }

    }
}
private struct PassedGuestCard: View {
    let record: PassedAccess
    let edit: () -> Void
    let message: () -> Void
    let remove: () -> Void
    @State private var expanded = false
    @State private var showingQR = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Button { withAnimation(.easeInOut(duration:0.18)) { expanded.toggle() } } label: {
                HStack(spacing:12) {
                    GuestKeyAvatar()
                    VStack(alignment:.leading,spacing:5) {
                        Text(record.label).font(.headline).foregroundStyle(Brand.ink)
                        Text(ProductText.string("guests_objects_count",record.parts.reduce(0) { $0 + $1.objects.count })).font(.footnote)
                        if !record.parts.allSatisfy({ $0.state == .active }) { Text(passedAccessStatus(record)).font(.footnote) }
                    }.foregroundStyle(Brand.secondaryInk).frame(maxWidth:.infinity,alignment:.leading)
                    Image(systemName:expanded ? "chevron.up" : "chevron.down").foregroundStyle(Brand.secondaryInk)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                CenteredIconActions {
                    GuestIconButton("gearshape",label:ProductText.string("guests_edit_desc"),action:edit)
                    GuestIconButton("doc.on.doc",label:ProductText.string("btn_copy")) { UIPasteboard.general.string = record.link?.url }.disabled(record.link == nil)
                    GuestIconButton("qrcode",label:"QR") { showingQR = true }.disabled(record.link == nil)
                    if let link = record.link {
                        ShareLink(item:link.url) { Image(systemName:"square.and.arrow.up").resizable().scaledToFit().frame(width:24,height:24) }
                            .buttonStyle(SquareIconActionStyle()).accessibilityLabel(ProductText.string("guests_share_chooser"))
                    }
                    GuestIconButton("envelope",label:ProductText.string("msg_send_icon_desc"),action:message).disabled(!record.parts.contains(where:{ $0.childID != nil }))
                    GuestIconButton("trash",label:ProductText.string("btn_delete"),destructive:true,action:remove)
                }.frame(maxWidth:.infinity)
            }
        }.padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20))
            .sheet(isPresented:$showingQR) { if let link = record.link { LinkQRCodeSheet(text:link.url) } }
    }
}

/// All existing parts are edited in one object form, in the same source order.
/// Each metadata edit remains durable before its request. A partial/uncertain
/// response keeps the sheet and saved state available for reconciliation.
private struct PassedObjectsEditor: View {
    @ObservedObject var manager: PassManager
    let accessID: UUID
    var body: some View { PassAccessForm(manager:manager,accessID:accessID) }
}
