import SwiftUI
import EntrixyCore

struct ServerSettingsPrompt: Identifiable {
    enum Action { case configure(String?, initial: String), forget(String) }
    let id = UUID()
    let action: Action
}

/// Android System's server rows stay in System; editing is one common dialog.
struct ServerSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    private var hosts: [String] { ["entrixy.com"] + Set(model.owners.map(\.server) + [model.selectedOwnerServer]).filter { $0 != "entrixy.com" }.sorted() }
    var body: some View {
        Section {
            Text(ProductText.string("server_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            ForEach(hosts,id:\.self) { host in
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:8) {
                        Button { model.selectOwnerServer(host) } label: {
                            HStack(spacing:12) {
                                Image(systemName:model.selectedOwnerServer == host ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(model.selectedOwnerServer == host ? AppPalette.selected : Brand.secondaryInk)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(host).font(.body.weight(.semibold))
                                    if let mail = model.owners.first(where:{ $0.server == host })?.serverSettings?.accountEmail { Text(mail).font(.caption).foregroundStyle(Brand.secondaryInk) }
                                }.frame(maxWidth:.infinity,alignment:.leading)
                            }.frame(minHeight:48).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("server-select-" + host)
                            .accessibilityAddTraits(model.selectedOwnerServer == host ? .isSelected : [])
                        icon("pencil",title:"server_edit") { model.serverPrompt = ServerSettingsPrompt(action:.configure(host,initial:host)) }
                        if host != "entrixy.com" { icon("trash",title:"server_forget",destructive:true) { model.serverPrompt = ServerSettingsPrompt(action:.forget(host)) } }
                        else { Color.clear.frame(width:44,height:48).accessibilityHidden(true) }
                    }
                    if let message = model.ownerMessages[host] { Text(message).font(.footnote).foregroundStyle(Brand.secondaryInk) }
                    if model.canSaveOwnerAccess(host) {
                        Button(ProductText.string("ios_server_save_access")) { Task { await model.retrySavingOwnerAccess(host) } }.buttonStyle(SecondaryActionStyle())
                    }
                }.foregroundStyle(Brand.ink)
            }
        } header: { Text(ProductText.string("server_section")) }
            .disabled(model.ownerBusy || model.busy || !model.canManageGuestAccess)
        Section {
            Button(ProductText.string("server_add")) { model.serverPrompt = ServerSettingsPrompt(action:.configure(nil,initial:"")) }
                .buttonStyle(SecondaryActionStyle()).actionListRow().accessibilityIdentifier("server-add")
        }.disabled(model.ownerBusy || model.busy || !model.canManageGuestAccess)
    }
    private func icon(_ image: String,title: String,destructive: Bool = false,action: @escaping () -> Void) -> some View {
        Button(action:action) { Image(systemName:image).resizable().scaledToFit().frame(width:24,height:24) }
            .buttonStyle(SquareIconActionStyle(destructive:destructive)).accessibilityLabel(ProductText.string(title))
    }
}

struct ServerSettingsDialog: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let prompt: ServerSettingsPrompt
    var completion: (() -> Void)? = nil
    @State private var server = ""
    @State private var accessCode = ""
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var feedback: String?
    private var editingHost: String? { if case .configure(let host,_) = prompt.action { return host }; return nil }
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    private func close() { password = ""; email = ""; model.serverPrompt = nil; completion?() }
    var body: some View {
        Group {
            switch prompt.action {
            case .configure: configuration
            case .forget(let host):
                AppConfirmationDialog(title:ProductText.string("server_forget_title"),message:ProductText.string("ios_server_forget_body",host) + (model.selectedOwnerServer == host ? "\n\n" + ProductText.string("server_forget_current") : ""),actionTitle:ProductText.string("server_forget"),destructive:true,cancel:close,confirm:{ if model.forgetOwnerServer(host) { close() } })
            }
        }.task {
            if case .configure(let existing,let initial) = prompt.action {
                server = existing ?? initial
                accessCode = model.owners.first(where:{ $0.server == server })?.serverSettings?.accessCode ?? ""
            }
        }.onDisappear { password = ""; email = "" }
            .onChange(of:scenePhase) { if $0 != .active { password = ""; email = ""; if !working { close() } } }
    }
    private var configuration: some View {
        AppDialogSurface {
            VStack(alignment:.leading,spacing:16) {
                Text(ProductText.string(editingHost == nil ? "server_add" : "server_edit")).font(.title3.bold())
                Text(ProductText.string("server_add_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                AppField(ProductText.string("server_host_label")) {
                    TextField(ProductText.string("server_host_label"),text:$server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(editingHost != nil).accessibilityIdentifier("server-host").serverField()
                }
                AppField(ProductText.string("server_code_label")) {
                    SecureField(ProductText.string("server_code_label"),text:$accessCode).textInputAutocapitalization(.never).autocorrectionDisabled().serverField()
                }
                Text(ProductText.string("account_section")).font(.headline)
                Text(ProductText.string("account_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                if let linked = owner?.serverSettings?.accountEmail {
                    Text(ProductText.string("account_linked",linked))
                    Button(ProductText.string("account_unlink"),role:.destructive) { unlink() }.buttonStyle(SecondaryActionStyle())
                } else {
                    AppField(ProductText.string("account_email")) { TextField(ProductText.string("account_email"),text:$email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().serverField() }
                    AppField(ProductText.string("account_password")) { SecureField(ProductText.string("account_password"),text:$password).textContentType(.password).serverField() }
                }
                if owner?.serverSettings?.pendingAccount?.sent == true { Text(ProductText.string("ios_server_account_uncertain")).font(.footnote).foregroundStyle(Brand.secondaryInk) }
                if let feedback { Text(feedback).font(.footnote).foregroundStyle(AppPalette.destructive) }

            }.disabled(working || model.ownerBusy || model.busy || !model.canManageGuestAccess)
        } footer: {
                EqualActionRow {
                    Button(ProductText.string("btn_cancel"),action:close).buttonStyle(SecondaryActionStyle())
                    Button { save() } label: { ActionButtonLabel(title:ProductText.string(editingHost == nil ? "btn_add" : "btn_save"),busy:working) }.buttonStyle(PrimaryActionStyle()).disabled(server.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.disabled(working || model.ownerBusy || model.busy || !model.canManageGuestAccess)
        }
    }
    private func save() {
        guard !working else { return }; working = true; feedback = nil
        let secret = password; password = ""
        Task {
            defer { working = false }
            if await model.saveServerConfiguration(server:server,accessCode:accessCode,email:email,password:secret) { close() }
            else { feedback = model.errorMessage; model.errorMessage = nil }
        }
    }
    private func unlink() {
        guard !working else { return }; working = true; feedback = nil
        Task { defer { working = false }; if !(await model.unlinkServerAccount(server)) { feedback = model.errorMessage; model.errorMessage = nil } }
    }
}

private extension View {
    func serverField() -> some View { padding(14).background(Color(uiColor:.tertiarySystemFill),in:RoundedRectangle(cornerRadius:DesignMetrics.actionRadius)) }
}
