import SwiftUI
import EntrixyCore

enum GuestRemovalTarget {
    case key(GuestKeyRow), company(KnownCompany), passed(PassedAccess)
}
struct GuestRemovalDialog: View {
    @EnvironmentObject private var app: AppModel
    let target: GuestRemovalTarget
    private var title: String {
        if case .company = target { return ProductText.string("guests_org_delete") }
        return ProductText.string("guest_delete_title")
    }
    private var message: String {
        switch target {
        case .key(let row): return row.key.label + "\n" + ProductText.string("passon_delete_warning")
        case .company(let company): return company.name
        case .passed: return ProductText.string("passon_delete_warning")
        }
    }
    var body: some View {
        AppConfirmationDialog(title:title,message:message,actionTitle:ProductText.string("btn_delete"),destructive:true,cancel:{ app.guestRemovalTarget = nil },confirm:{
            app.guestRemovalTarget = nil
            Task {
                switch target {
                case .key(let row): await app.revokeOwnerKey(server:row.server,keyID:row.key.id)
                case .company(let company): await app.forgetCompany(company.id)
                case .passed(let record): await app.passManager.revoke(record.id,retry:true)
                }
            }
        })
    }
}

private enum GuestsTab: String, CaseIterable {
    case people = "guests_tab_people", companies = "guests_tab_orgs", presets = "guests_tab_presets"
}
private enum GuestTask: Identifiable {
    case issue, company(String?), edit(String,UUID), qr(String,UUID), message(String,UUID), recovery(String,UUID)
    var id: String {
        switch self {
        case .issue: return "issue"
        case .company(let id): return "company:" + (id ?? "")
        case let .edit(s,id): return "edit:\(s):\(id)"
        case let .qr(s,id): return "qr:\(s):\(id)"
        case let .message(s,id): return "message:\(s):\(id)"
        case let .recovery(s,id): return "recovery:\(s):\(id)"
        }
    }
}

/// GuestsScreen.kt: three own-access tabs, expandable guest actions and the
/// received-access section underneath. Main navigation remains in RootView.
struct OwnerGuestsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: GuestsTab = .people
    @State private var task: GuestTask?
    @State private var scanning = false
    private var hasOwn: Bool { model.navigationState.hasOwnObjects }
    private var hasObjects: Bool { model.owners.contains { !($0.objects ?? []).filter({ $0.numberID != nil && $0.pending == nil && $0.available != false }).isEmpty } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if hasOwn {
                    if model.navigationState.canDelegate, !model.guestPeople.isEmpty {
                        Text(ProductText.string("guests_add")).font(.headline)
                    }
                    Picker(ProductText.string("guests_tab_people"),selection:$tab) {
                        ForEach(GuestsTab.allCases,id:\.self) { Text(ProductText.string($0.rawValue)).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("guests-sections")
                    switch tab {
                    case .people: people
                    case .companies: companies
                    case .presets: GuestPresets()
                    }
                    guestRecovery
                }
                if model.navigationState.canDelegate || !model.passedAccess.isEmpty {
                    PassedGuestsSection(otherSection:hasOwn)
                }
            }.padding(.horizontal,DesignMetrics.pageInset).padding(.bottom,32)
        }.background(Color(uiColor:.systemGroupedBackground)).navigationTitle("Гости")
            .refreshable { await model.refreshOwners(); await model.passManager.reload() }
            .sheet(item:$task) { value in
                switch value {
                case .issue: IssueOwnerKeyScreen()
                case .company(let id): IssueOwnerKeyScreen(companySelection:true,companyPreset:id)
                case let .edit(s,id): IssueOwnerKeyScreen(serverPreset:s,editingKeyID:id)
                case let .qr(s,id): GuestQRSheet(server:s,keyID:id)
                case let .message(s,id): ComposeMessageScreen(manager:model.messages,target:.owner(server:s,keyID:id))
                case let .recovery(s,id): NavigationStack { OwnerKeyScreen(server:s,keyID:id) }
                }
            }
            .sheet(isPresented:$scanning) {
                QRScannerScreen { raw in
                    scanning = false
                    do { let invite = try CompanyInvite.parse(raw); Task { await model.receiveCompanyInvite(invite) } }
                    catch { model.errorMessage = "В QR-коде не найден запрос компании Entrixy." }
                }
            }
            .onChange(of:model.companyGrantRequest) { id in
                guard let id else { return }; tab = .companies; model.companyGrantRequest = nil
                if let company = model.companies.first(where:{ $0.id == id }) { open(company) }
            }
            .task {
                if let id = model.companyGrantRequest { tab = .companies; model.companyGrantRequest = nil; if let company = model.companies.first(where:{ $0.id == id }) { open(company) } }
            }

    }
    private var people: some View {
        VStack(spacing:12) {
            ForEach(model.guestPeople) { row in
                GuestPersonCard(row:row,edit:{ task = .edit(row.server,row.key.id) },qr:{ task = .qr(row.server,row.key.id) },message:{ task = .message(row.server,row.key.id) },recovery:{ task = .recovery(row.server,row.key.id) },remove:{ model.guestRemovalTarget = .key(row) })
            }
            if hasObjects {
                Button { task = .issue } label: { Label(ProductText.string("guests_add"),systemImage:"plus") }.buttonStyle(PrimaryActionStyle()).disabled(model.ownerBusy)
                    .accessibilityIdentifier("issue-guest")
            }
        }
    }
    private var companies: some View {
        VStack(spacing:12) {
            if model.companies.isEmpty { Text(ProductText.string("guests_orgs_empty")).foregroundStyle(Brand.secondaryInk).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,12) }
            ForEach(model.companies) { company in
                HStack(spacing:12) {
                    Button { open(company) } label: {
                        HStack(spacing:12) {
                            CompanyAvatar(company:company)
                            VStack(alignment:.leading,spacing:5) {
                                Text(company.name).font(.headline).foregroundStyle(Brand.ink)
                                Text(company.domain ?? ProductText.string("org_domain_none")).font(.footnote).foregroundStyle(company.proven ? Brand.ink : AppPalette.destructive)
                                let keys = model.companyKeys(company)
                                Text(keys.isEmpty ? ProductText.string("guests_org_no_access") : ProductText.string("guests_org_objects_count",Set(keys.flatMap { $0.effectiveNumberIDs ?? $0.numberIDs }).count)).font(.footnote).foregroundStyle(Brand.secondaryInk)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    GuestIconButton("trash",label:ProductText.string("guests_org_delete"),destructive:true) { model.guestRemovalTarget = .company(company) }
                }.padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20))
            }
            if !model.companies.isEmpty, hasObjects {
                Button { task = .company(nil) } label: { Label(ProductText.string("guests_add_org"),systemImage:"plus") }.buttonStyle(PrimaryActionStyle()).disabled(model.ownerBusy || model.companyBusy)
            }
            Button { scanning = true } label: { Label(ProductText.string("guests_org_scan"),systemImage:"qrcode.viewfinder") }.buttonStyle(SecondaryActionStyle()).disabled(model.companyBusy)
        }
    }
    private func open(_ company: KnownCompany) {
        if let existing = model.companyKeys(company).first {
            task = existing.pending == nil ? .edit(company.server,existing.id) : .recovery(company.server,existing.id)
        } else if hasObjects { task = .company(company.id) }
        else { model.errorMessage = ProductText.string("guests_no_objects_first") }
    }
    @ViewBuilder private var guestRecovery: some View {
        ForEach(model.owners.filter { !($0.androidKeys ?? []).isEmpty }) { owner in
            VStack(alignment:.leading,spacing:8) {
                Text("Сохранённые ключи Android: \(owner.androidKeys?.count ?? 0)").font(.headline)
                Text("Для восстановления нужно подтвердить связку и правила передачи. Секреты сохранены.").font(.footnote).foregroundStyle(Brand.secondaryInk)
                Button("Проверить данные сервера") { Task { await model.refreshOwners() } }.buttonStyle(SecondaryActionStyle()).disabled(model.ownerBusy)
            }.padding(.top,12)
        }
    }
}

struct GuestKeyRow: Identifiable {
    let owner: OwnerAccount
    let key: OwnerIssuedKey
    var server: String { owner.server }
    var id: UUID { key.id }
}
extension AppModel {
    var guestPeople: [GuestKeyRow] {
        owners.flatMap { owner in
            (owner.issuedKeys ?? []).filter { $0.company == nil && $0.state != .revoked }.map { GuestKeyRow(owner:owner,key:$0) }
        }
    }
}

private struct GuestPersonCard: View {
    @EnvironmentObject private var model: AppModel
    let row: GuestKeyRow
    let edit: () -> Void
    let qr: () -> Void
    let message: () -> Void
    let recovery: () -> Void
    let remove: () -> Void
    @State private var expanded = false
    private var key: OwnerIssuedKey { row.key }
    private var link: URL? { try? key.link(server:row.server,masterKey:row.owner.masterKey,allowPaused:true) }
    private var shareText: String {
        let welcome = (try? key.bundle(masterKey:row.owner.masterKey)["welcome"] as? String) ?? ""
        return (welcome.isEmpty ? "" : welcome + "\n\n") + (link?.absoluteString ?? "")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Button { withAnimation(.easeInOut(duration:0.18)) { expanded.toggle() } } label: {
                HStack(spacing:12) {
                    GuestKeyAvatar()
                    VStack(alignment:.leading,spacing:5) {
                        Text(key.label).font(.headline).foregroundStyle(Brand.ink)
                        Text(ProductText.string("guests_objects_count",(key.effectiveNumberIDs ?? key.numberIDs).count)).font(.footnote)
                        let count = (row.owner.delegatedKeys ?? []).filter { $0.rootID == key.id && $0.state != .revoked }.count
                        if count > 0 { Text(ProductText.string("guests_passed_count",count)).font(.footnote) }
                        if key.pending != nil || key.state != .active { Text(ownerKeyStatus(key)).font(.footnote) }
                    }.foregroundStyle(Brand.secondaryInk).frame(maxWidth:.infinity,alignment:.leading)
                    Image(systemName:expanded ? "chevron.up" : "chevron.down").foregroundStyle(Brand.secondaryInk)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("guest-card-" + key.id.uuidString)
            if key.pending != nil {
                Text(model.ownerKeyMessages[key.id] ?? ownerKeyStatus(key)).font(.footnote).foregroundStyle(Brand.secondaryInk)
                Button(ProductText.string("btn_retry"),action:recovery).buttonStyle(SecondaryActionStyle())
            }
            if expanded {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:0) {
                        GuestIconButton("gearshape",label:ProductText.string("guests_edit_desc"),action:edit).disabled(key.pending != nil)
                        GuestIconButton("plus",label:ProductText.string("guests_clone_desc")) { Task { await model.cloneOwnerKey(server:row.server,keyID:key.id) } }.disabled(!model.canCloneOwnerKey(server:row.server,keyID:key.id))
                        GuestIconButton("qrcode",label:"QR",action:qr).disabled(link == nil)
                        ShareLink(item:shareText) { Image(systemName:"square.and.arrow.up").font(.system(size:22)).frame(width:44,height:48) }.buttonStyle(.plain).disabled(link == nil).accessibilityLabel(ProductText.string("guests_share_chooser"))
                        GuestIconButton("envelope",label:ProductText.string("msg_send_icon_desc"),action:message).disabled(key.pending != nil || ![.active,.paused,.restricted].contains(key.state))
                        GuestIconButton(key.state == .paused ? "play.fill" : "pause.fill",label:ProductText.string(key.state == .paused ? "guest_key_resume" : "guest_key_pause")) { Task { await model.setOwnerKeyMode(server:row.server,keyID:key.id,paused:key.state != .paused) } }.disabled(key.pending != nil || ![.active,.paused].contains(key.state))
                        GuestIconButton("trash",label:ProductText.string("btn_delete"),destructive:true,action:remove).disabled(key.keyID == nil)
                    }.foregroundStyle(Brand.ink)
                }.disabled(model.ownerBusy || model.busy)
            }
        }.padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20))
    }
}

struct GuestIconButton: View {
    let symbol: String
    let label: String
    var destructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    init(_ symbol: String,label: String,destructive: Bool = false,action: @escaping () -> Void) { self.symbol = symbol; self.label = label; self.destructive = destructive; self.action = action }
    var body: some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:22)).frame(width:44,height:48).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(enabled ? (destructive ? AppPalette.destructive : Brand.ink) : Brand.secondaryInk.opacity(0.5)).accessibilityLabel(label)
    }
}
struct GuestKeyAvatar: View {
    var body: some View { Image(systemName:"key").font(.system(size:23)).foregroundStyle(Brand.ink).frame(width:48,height:48).background(AppPalette.secondary,in:Circle()).accessibilityHidden(true) }
}

private struct GuestPresets: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            VStack(alignment:.leading,spacing:8) {
                AppField(ProductText.string("owner_name_placeholder")) {
                    TextField(ProductText.string("owner_name_placeholder"),text:$name).padding(14).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:12)).focused($focused).submitLabel(.done).textInputAutocapitalization(.words)
                        .onSubmit { saveName(); focused = false }
                        .onChange(of:name) { name = String($0.replacingOccurrences(of:"\n",with:"").replacingOccurrences(of:"\r",with:"").prefix(40)) }
                }
                Text(ProductText.string("owner_name_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            }
            VStack(alignment:.leading,spacing:5) {
                Text(ProductText.string("presets_access_title")).font(.headline)
                Text(ProductText.string("presets_access_hint")).font(.subheadline).foregroundStyle(Brand.secondaryInk)
            }
            GuestAccessFields(value:Binding(get:{ model.ownerGuestDefaults.access },set:{ value in var defaults = model.ownerGuestDefaults; defaults.access = value; _ = model.saveGuestDefaults(defaults) }))
        }.padding(.vertical,8).disabled(model.ownerBusy || !model.canManageGuestAccess)
            .onAppear { name = model.ownerGuestDefaults.ownerName }
            .onDisappear { saveName() }
            .onChange(of:focused) { if !$0 { saveName() } }
    }
    private func saveName() {
        var defaults = model.ownerGuestDefaults; defaults.ownerName = name.trimmingCharacters(in:.whitespacesAndNewlines)
        if defaults != model.ownerGuestDefaults { _ = model.saveGuestDefaults(defaults) }
    }
}

private struct GuestQRSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    let keyID: UUID
    var body: some View {
        NavigationStack {
            ScrollView {
                if let owner = model.owners.first(where:{ $0.server == server }), let key = owner.issuedKeys?.first(where:{ $0.id == keyID }), let link = try? key.link(server:server,masterKey:owner.masterKey,allowPaused:true) {
                    VStack(spacing:20) {
                        InviteQRCode(text:link.absoluteString).onTapGesture { dismiss() }
                        Text(ProductText.string("guests_qr_close")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                        Button(ProductText.string("btn_copy")) { UIPasteboard.general.string = link.absoluteString }.buttonStyle(SecondaryActionStyle())
                    }.padding(DesignMetrics.pageInset)
                }
            }.background(Color(uiColor:.systemGroupedBackground)).navigationTitle("QR").navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(ProductText.string("btn_close")) { dismiss() }
        }
    }
}
