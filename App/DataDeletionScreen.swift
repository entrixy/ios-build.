import SwiftUI
import EntrixyCore

struct DataDeletionServersScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: DeletionServer?
    private struct DeletionServer: Identifiable { let id: String }
    var body: some View {
        List {
            Section { Text(ProductText.string("ios_deletion_hint")).foregroundStyle(Brand.secondaryInk) }
            let owners = model.owners.filter { $0.credentials != nil }
            if owners.isEmpty { Text(ProductText.string("ios_deletion_no_servers")) }
            ForEach(owners, id: \.server) { owner in
                Button { selected = DeletionServer(id: owner.server) } label: {
                    HStack { Text(owner.server); Spacer(); Image(systemName: "chevron.right") }
                        .foregroundStyle(Brand.ink).frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("data-deletion-server-" + owner.server)
            }
        }.scrollContentBackground(.hidden).background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(ProductText.string("ios_deletion_title")).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { DataDeletionForm(server: $0.id).environmentObject(model) }
    }
}

struct DataDeletionForm: View {
    let server: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var scope = DataDeletionScope.device
    @State private var confirmation = ""
    @State private var password = ""
    @State private var working = false
    @State private var configured = false
    @State private var feedback: String?
    @FocusState private var confirming: Bool
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    private var receipt: DataDeletionReceipt? { owner?.serverSettings?.deletionReceipt }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(server).font(.headline)
                    if let result = receipt?.result {
                        Text(ProductText.string(result.status == .pending ? "ios_deletion_pending" : "ios_deletion_complete"))
                            .accessibilityIdentifier("data-deletion-status")
                        if result.status == .pending {
                            Text(ProductText.string("ios_deletion_due", ProductText.date(Date(timeIntervalSince1970: TimeInterval(result.expectedBy)), timeStyle: .omitted)))
                                .font(.subheadline).foregroundStyle(Brand.secondaryInk)
                        }
                        Button(ProductText.string("ios_deletion_check")) { refresh() }.buttonStyle(SecondaryActionStyle()).disabled(working)
                    } else {
                        Text(ProductText.string("ios_deletion_hint"))
                        if receipt != nil { Text(ProductText.string("ios_deletion_prepared")).font(.footnote).foregroundStyle(Brand.secondaryInk) }
                        if receipt == nil {
                            ForEach(DataDeletionScope.allCases, id: \.rawValue) { option in
                                if option == .device || owner?.serverSettings?.accountEmail != nil {
                                    Button { scope = option } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: scope == option ? "largecircle.fill.circle" : "circle")
                                                .foregroundStyle(scope == option ? AppPalette.selected : Brand.secondaryInk)
                                            Text(ProductText.string("ios_deletion_" + option.rawValue)).frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(minHeight: 48).foregroundStyle(Brand.ink)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        Text(ProductText.string("ios_deletion_" + scope.rawValue + "_hint")).foregroundStyle(Brand.secondaryInk)
                        if scope == .account {
                            Text(owner?.serverSettings?.accountEmail ?? "").font(.subheadline)
                            AppField(ProductText.string("account_password")) {
                                SecureField(ProductText.string("account_password"), text: $password).textContentType(.password)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().serverField()
                                    .accessibilityIdentifier("data-deletion-password")
                            }
                        }
                        AppField(ProductText.string("ios_deletion_confirmation")) {
                            TextField("DELETE", text: $confirmation).textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .keyboardType(.asciiCapable).serverField().accessibilityIdentifier("data-deletion-confirmation")
                                .focused($confirming).submitLabel(.done).onSubmit { confirming = false }
                        }
                        Button(ProductText.string("ios_deletion_submit"), role: .destructive) { submit() }
                            .buttonStyle(PrimaryActionStyle()).disabled(working || confirmation != "DELETE" || (scope == .account && password.isEmpty))
                            .accessibilityIdentifier("data-deletion-submit")
                        if receipt != nil { Button(ProductText.string("ios_deletion_check")) { refresh() }.buttonStyle(SecondaryActionStyle()).disabled(working) }
                    }
                    if let feedback { Text(ProductText.systemMessage(feedback)).foregroundStyle(AppPalette.destructive).fixedSize(horizontal: false, vertical: true) }
                    if working { ProgressView() }
                }.padding(DesignMetrics.pageInset)
            }.scrollDismissesKeyboard(.interactively).background(Color(uiColor: .systemGroupedBackground))
                .taskSheetTitle(ProductText.string("ios_deletion_title"))
                .sheetDismissFooter(ProductText.string(receipt == nil ? "btn_cancel" : "btn_close"), disabled: working) { password = ""; dismiss() }
        }.interactiveDismissDisabled(working)
            .task { guard !configured else { return }; configured = true; scope = receipt?.scope ?? (owner?.serverSettings?.accountEmail == nil ? .device : .account) }
            .onDisappear { password = ""; confirmation = "" }
            .onChange(of: phase) { if $0 != .active { password = ""; confirmation = "" } }
    }
    private func submit() {
        guard confirmation == "DELETE", !working else { return }; working = true; feedback = nil
        let secret = password, typed = confirmation; password = ""; confirmation = ""
        Task { defer { working = false }; if !(await model.submitDataDeletion(server: server, scope: scope, password: secret, confirmation: typed)) { feedback = model.errorMessage; model.errorMessage = nil } }
    }
    private func refresh() {
        guard !working else { return }; working = true; feedback = nil
        Task { defer { working = false }; if !(await model.refreshDataDeletion(server: server)) { feedback = model.errorMessage; model.errorMessage = nil } }
    }
}
