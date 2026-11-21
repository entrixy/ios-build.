import SwiftUI

struct LocalResetScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @FocusState private var confirming: Bool
    var body: some View {
        NavigationStack {
            if model.localDataErased { LocalResetCompleteScreen() }
            else {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        Text(ProductText.string("ios_reset_explanation")).fixedSize(horizontal:false,vertical:true)
                        Text(ProductText.string("ios_reset_backup_warning")).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                        AppField(ProductText.string("ios_reset_confirmation")) {
                            TextField("RESET",text:$confirmation).keyboardType(.asciiCapable)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .focused($confirming).submitLabel(.done).onSubmit { confirming = false }
                                .padding(14).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:12))
                                .accessibilityIdentifier("local-reset-confirmation")
                        }
                        Button(ProductText.string("ios_reset_action"),role:.destructive) {
                            _ = model.eraseLocalData(confirmation:confirmation)
                        }.buttonStyle(PrimaryActionStyle()).disabled(confirmation != "RESET" || !model.storageReady || model.busy || model.ownerBusy)
                            .accessibilityIdentifier("local-reset-erase")
                        if let error = model.errorMessage { Text(ProductText.systemMessage(error)).foregroundStyle(AppPalette.destructive).fixedSize(horizontal:false,vertical:true) }
                    }.padding(DesignMetrics.pageInset)
                }.scrollDismissesKeyboard(.interactively).background(Color(uiColor:.systemGroupedBackground))
                    .taskSheetTitle(ProductText.string("ios_reset_title"))
                    .sheetDismissFooter { dismiss() }
            }
        }.interactiveDismissDisabled(model.localDataErased)
    }
}

struct LocalResetCompleteScreen: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text(ProductText.string("ios_reset_complete")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("local-reset-complete")
            Text(ProductText.string("ios_reset_remote_unchanged")).fixedSize(horizontal:false,vertical:true)
            if model.localResetCleanupPending {
                Text(ProductText.string("ios_reset_cleanup_failed")).foregroundStyle(AppPalette.destructive)
                Button(ProductText.string("btn_retry")) { _ = model.finishLocalResetCleanup() }.buttonStyle(PrimaryActionStyle())
            } else {
                Text(ProductText.string("ios_reset_restore_hint")).foregroundStyle(Brand.secondaryInk)
                Button(ProductText.string("ios_reset_restart")) {
                    LiveAppRuntime.restartAfterLocalReset(model)
                }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("local-reset-restart")
            }
        }.padding(DesignMetrics.pageInset).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(Color(uiColor:.systemGroupedBackground)).interactiveDismissDisabled()
    }
}
