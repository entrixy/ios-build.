import SwiftUI
import EntrixyCore

struct ImportedGuestKeyRow: View {
    @EnvironmentObject private var model: AppModel
    let source: AndroidGuestMigration
    @ObservedObject var manager: BackupManager
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(source.label.isEmpty ? ProductText.string("guests_default_name") : source.label).font(.headline).frame(maxWidth:.infinity,alignment:.leading)
                GuestIconButton("trash",label:ProductText.string("btn_delete"),destructive:true) { model.guestRemovalTarget = .imported(source) }.disabled(manager.busy)
            }
            Text(source.identity.server).font(.subheadline).foregroundStyle(Brand.secondaryInk)
            Text(manager.importMessages[source.id] ?? ProductText.string("guests_key_awaiting_bundle")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            Button(ProductText.string("btn_retry")) {
                Task { await manager.recoverImportedGuest(source.id); if !model.androidPendingGuests.contains(where:{ $0.id == source.id }) { await model.refresh() } }
            }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || model.busy)
        }.padding(.vertical,8)
    }
}
