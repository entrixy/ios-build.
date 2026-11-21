import SwiftUI
import CoreImage.CIFilterBuiltins
import EntrixyCore

func ownerKeyStatus(_ key: OwnerIssuedKey) -> String {
    if key.pending != nil { return key.sent ? ProductText.string("ios_server_confirmation_pending") : ProductText.string("ios_request_not_applied_yet") }
    switch key.state {
    case .active: return ProductText.string("ios_access_active")
    case .paused: return ProductText.string("ios_access_paused")
    case .revoked: return ProductText.string("ios_key_revoked")
    case .draft: return ProductText.string("ios_key_preparing")
    case .unavailable: return ProductText.string("ios_key_server_unavailable")
    case .restricted: return ProductText.string("ios_owner_processing_required")
    }
}

private enum GuestObjectTask: Identifiable {
    case automation(ObjectReference), invocation(ObjectReference), access(ObjectReference)
    var target: ObjectReference { switch self { case .automation(let t), .invocation(let t), .access(let t): return t } }
    var id: String { switch self { case .automation: return "auto:" + target.id; case .invocation: return "call:" + target.id; case .access: return "access:" + target.id } }
}

struct IssueOwnerKeyScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editingKeyID: UUID?
    private let companySelection: Bool
    @State private var companyID: String
    @StateObject private var draft = GuestKeyDraft()
    @State private var server: String
    @State private var loaded = false
    @State private var label = ""
    @State private var welcome = ""
    @State private var task: GuestObjectTask?
    init(serverPreset: String? = nil, editingKeyID: UUID? = nil, editAccessOnLaunch: Bool = false, companySelection: Bool = false, companyPreset: String? = nil) {
        self.editingKeyID = editingKeyID; _server = State(initialValue: serverPreset ?? "")
        self.companySelection = companySelection; _companyID = State(initialValue:companyPreset ?? "")
    }
    private var owner: OwnerAccount? { model.owners.first { $0.server == server && !$0.registrationPending } }
    private var editingKey: OwnerIssuedKey? { owner?.issuedKeys?.first(where:{ $0.id == editingKeyID }) }
    private var forCompany: Bool { companySelection || editingKey?.company != nil }
    private var company: KnownCompany? { model.companies.first { $0.id == companyID } }
    private func host(_ entry: CatalogObject) -> String {
        if case let .owned(account, _) = entry { return account.server }; return ""
    }
    private var rows: [CatalogObject] {
        let values = model.catalogObjects().filter {
            guard case let .owned(account, _) = $0, !account.registrationPending else { return false }
            if forCompany, case let .owned(_,object) = $0 { return object.kind == "call" && account.server == server }
            return editingKeyID == nil || account.server == server
        }
        var hosts: [String] = []
        for entry in values where !hosts.contains(host(entry)) { hosts.append(host(entry)) }
        return hosts.flatMap { hostname in values.filter { host($0) == hostname } }
    }
    private func startsGroup(_ entry: CatalogObject) -> Bool {
        Set(rows.map(host)).count > 1 && rows.first(where: { host($0) == host(entry) })?.id == entry.id
    }
    private func eligible(_ object: OwnerObject) -> Bool {
        object.numberID != nil && object.pending == nil && object.available != false && (object.kind != "device" || object.wrappedSocketSecret != nil)
    }
    private func access(_ number: Int) -> KeyObjectAccess { draft.access[number] ?? (editingKeyID == nil ? model.ownerGuestDefaults.access : (try! KeyObjectAccess())) }
    private func toggle(_ account: OwnerAccount, _ object: OwnerObject) {
        guard let number = object.numberID, eligible(object), !account.isMoving(object.id) else { return }
        if draft.selected.isEmpty, editingKeyID == nil, !forCompany, server != account.server {
            draft.access = [:]; draft.templates = [:]; draft.streams = [:]; draft.lifetimes = [:]; draft.calls = [:]
            server = account.server
        }
        guard server == account.server else { return }
        if draft.selected.contains(number) { draft.selected.remove(number) }
        else { draft.selected.insert(number); if draft.access[number] == nil { draft.access[number] = model.ownerGuestDefaults.access } }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if forCompany {
                        if editingKeyID == nil {
                            Picker(ProductText.string("guests_org_pick"),selection:$companyID) {
                                Text(ProductText.string("guests_org_pick")).tag("")
                                ForEach(model.companies) { Text($0.name).tag($0.id) }
                            }.onChange(of:companyID) { _ in
                                server = company?.server ?? ""; label = company?.name ?? ""; draft.selected = []
                            }
                        }
                        if let company { CompanyGrantSummary(company:company) }
                        else if let editingKey { Text(editingKey.label).font(.headline) }
                    } else {
                    AppField(ProductText.string("guests_default_name")) {
                        TextField(ProductText.string("guests_default_name"), text: $label)
                            .onChange(of: label) { label = String($0.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "").prefix(64)) }
                    }
                    AppField(ProductText.string("guests_welcome_label")) {
                        TextField(ProductText.string("guests_welcome_hint"), text: $welcome, axis: .vertical)
                            .onChange(of: welcome) { welcome = String($0.prefix(500)) }
                    }
                    }
                }
                Section {
                    ForEach(rows) { entry in objectRow(entry) }
                    if rows.isEmpty { Text(ProductText.string("ios_add_object_first")).foregroundStyle(Brand.secondaryInk) }
                } header: { Text(ProductText.string("guests_objects_allowed")) }
                Section {
                    Button { Task { await save() } } label: {
                        ActionButtonLabel(title: editingKeyID == nil ? ProductText.string(forCompany ? "guests_add_org" : "guests_add") : ProductText.string("btn_save"), busy: model.ownerBusy)
                    }.buttonStyle(PrimaryActionStyle()).actionListRow().disabled(model.ownerBusy || draft.selected.isEmpty || (forCompany && editingKeyID == nil && company == nil) || (editingKeyID != nil && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }.taskSheetTitle(editingKeyID == nil ? ProductText.string(forCompany ? "guests_add_org" : "guests_add") : ProductText.string("guests_access_title"),form:true)
                .sheetDismissFooter(disabled: model.ownerBusy) { dismiss() }
                .task {
                    guard !loaded else { return }; loaded = true
                    if let editingKeyID, let owner, let key = owner.issuedKeys?.first(where: { $0.id == editingKeyID }) {
                        model.beginEditingGuestKey(editingKeyID)
                        do {
                            try draft.load(owner: owner, key: key)
                            label = key.label; welcome = try key.bundle(masterKey: owner.masterKey)["welcome"] as? String ?? ""
                            if let grant = key.company { companyID = model.companies.first(where:{ $0.server == owner.server && $0.companyID == grant.companyID })?.id ?? ""; welcome = "" }
                        } catch { model.errorMessage = ProductText.string("ios_key_settings_read_failed") }
                    } else if companySelection {
                        if companyID.isEmpty, model.companies.count == 1 { companyID = model.companies[0].id }
                        server = company?.server ?? ""; label = company?.name ?? ""
                    }
                }
                .onDisappear { if task == nil, let editingKeyID { model.endEditingGuestKey(editingKeyID) } }
                .sheet(item: $task, onDismiss: { if let owner { draft.syncSavedSettings(owner: owner) } }) { task in nested(task) }
                .appMessageDialog("Entrixy",message:model.errorMessage ?? "",actionTitle:ProductText.string("btn_ok"),isPresented:Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }))
        }
    }
    @ViewBuilder private func objectRow(_ entry: CatalogObject) -> some View {
        if case let .owned(account, object) = entry, let number = object.numberID {
            let selected = account.server == server && draft.selected.contains(number)
            let locked = !draft.selected.isEmpty && server != account.server
            VStack(alignment: .leading, spacing: 8) {
                if startsGroup(entry) {
                    Text(account.server).font(.footnote).foregroundStyle(Brand.secondaryInk)
                }
                HStack(spacing: 6) {
                    Button { toggle(account, object) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected ? AppPalette.selected : Brand.secondaryInk)
                            Text(model.objectLabel(entry)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.foregroundStyle(Brand.ink).frame(minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(locked || !eligible(object) || account.isMoving(object.id) || model.ownerBusy)
                        .accessibilityIdentifier("guest-object-" + entry.target.id)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    if selected {
                        if ["call", "webhook", "ble"].contains(object.kind) {
                            objectButton("hand.tap", label: ProductText.string(object.kind == "ble" ? "guest_key_ttl_title" : "guests_call_cfg_desc")) { task = .invocation(entry.target) }
                                .accessibilityIdentifier("guest-object-invocation-" + entry.target.id)
                        }
                        if !forCompany {
                            objectButton("arrow.triangle.2.circlepath", label: ProductText.string("guests_automation_desc")) { task = .automation(entry.target) }
                                .accessibilityIdentifier("guest-object-automation-" + entry.target.id)
                            objectButton("person.badge.key", label: ProductText.string("obj_access_desc")) { task = .access(entry.target) }
                                .accessibilityIdentifier("guest-object-access-" + entry.target.id)
                        }
                    }
                }
                if !forCompany, selected, object.kind != "ble", let camera = object.localConfiguration?.camera, camera.enabled, !camera.url.isEmpty {
                    Toggle(ProductText.string("guests_grant_video"), isOn: Binding(get: { draft.streams[number] ?? true }, set: { draft.streams[number] = $0 }))
                        .tint(AppPalette.selected).font(.subheadline).padding(.leading, 30)
                }
            }
        }
    }
    private func objectButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group { if symbol == "arrow.triangle.2.circlepath" { AutomationIcon() } else { Image(systemName:symbol).resizable().scaledToFit().frame(width:24,height:24) } }
        }
            .buttonStyle(SquareIconActionStyle()).accessibilityLabel(label)
    }
    @ViewBuilder private func nested(_ task: GuestObjectTask) -> some View {
        if case let .owned(host, id) = task.target, let account = model.owners.first(where: { $0.server == host }),
           let object = account.objects?.first(where: { $0.id == id }), let number = object.numberID {
            let saved = editingKeyID.flatMap { keyID in account.issuedKeys?.first(where: { $0.id == keyID && $0.numberIDs.contains(number) }) }
            switch task {
            case .automation:
                if let saved { AutomationEditor(destination: .issued(server: host, keyID: saved.id, objectID: id)) }
                else { DraftGuestAutomationEditor(draft: draft, server: host, objectID: id) }
            case .access:
                GuestObjectAccessEditor(title: model.objectLabel(.owned(account, object)), value: Binding(get: { access(number) }, set: { draft.access[number] = $0 }))
            case .invocation:
                if object.kind == "ble" {
                    GuestBLELifetimeEditor(label: model.objectLabel(.owned(account, object)), seconds: Binding(get: {
                        if let keyID = saved?.id { return model.owners.first(where: { $0.server == host })?.issuedKeys?.first(where: { $0.id == keyID })?.bleTokenLifetimes?[String(number)] ?? BLETokenLifetime.defaultValue }
                        return draft.lifetimes[number] ?? BLETokenLifetime.defaultValue
                    }, set: { seconds in
                        if let saved { if model.saveIssuedLifetime(server: host, keyID: saved.id, objectID: id, seconds: seconds) { draft.lifetimes[number] = seconds } }
                        else { draft.lifetimes[number] = seconds }
                    }))
                } else {
                    GuestInvocationEditor(server: host, objectID: id, preference: Binding(get: {
                        if let keyID = saved?.id { return model.owners.first(where: { $0.server == host })?.issuedKeys?.first(where: { $0.id == keyID })?.callPreferences?[String(number)] ?? OwnerCallPreference() }
                        return draft.calls[number] ?? OwnerCallPreference()
                    }, set: { preference in
                        if let saved { if model.saveIssuedCallPreference(server: host, keyID: saved.id, objectID: id, preference: preference) { draft.calls[number] = preference } }
                        else { draft.calls[number] = preference }
                    }))
                }
            }
        }
    }
    private func save() async {
        guard let owner else { return }
        do {
            draft.syncSavedSettings(owner: owner)
            let configuration = try draft.configuration(owner: owner)
            let rights = try Dictionary(uniqueKeysWithValues: draft.selected.map { ($0, forCompany ? try KeyObjectAccess(depth:0,pool:1) : access($0)) })
            let before = Set(owner.issuedKeys?.map(\.id) ?? [])
            let previousCipher = owner.issuedKeys?.first(where: { $0.id == editingKeyID })?.bundleCipher
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ProductText.string("guests_default_name") : label
            let result: Bool
            if let editingKeyID {
                result = await model.editOwnerKey(server: server, keyID: editingKeyID, label: name, numberIDs: Array(draft.selected), welcome: welcome, confirmation: nil, access: rights, settings: configuration)
            } else if forCompany {
                result = await model.issueCompanyAccess(profileID:companyID,numberIDs:Array(draft.selected),calls:configuration.calls)
            } else {
                result = await model.createOwnerKey(server: server, label: name, numberIDs: Array(draft.selected), welcome: welcome, nativeOnly: false, confirmation: false, access: rights, settings: configuration)
            }
            let after = model.owners.first { $0.server == server }?.issuedKeys ?? []
            if result || after.contains(where: { !before.contains($0.id) || ($0.id == editingKeyID && $0.bundleCipher != previousCipher && $0.pending != nil) }) {
                if let editingKeyID { model.endEditingGuestKey(editingKeyID) }
                dismiss()
            }
        } catch { model.errorMessage = ProductText.string("ios_access_settings_save_failed") }
    }
}

struct OwnerKeyScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: String
    let keyID: UUID
    @State private var revoking = false
    @State private var renewingBLE = false
    @State private var composing = false
    @State private var editing = false
    @State private var reviewingRestoredAccess = false
    var showRevokeOnLaunch = false
    private var owner: OwnerAccount? { model.owners.first { $0.server == server } }
    private var key: OwnerIssuedKey? { owner?.issuedKeys?.first { $0.id == keyID } }
    private var link: URL? { guard let owner, let key else { return nil }; return try? key.link(server: server, masterKey: owner.masterKey, allowPaused:true) }
    var body: some View {
        List {
            if let key {
                Section {
                    Text(key.label).font(.title3.bold())
                    Text(ownerKeyStatus(key)).foregroundStyle(Brand.secondaryInk)
                    KeyValueRow(title: ProductText.string("ble_server_label"), value: server)
                    KeyValueRow(title: ProductText.string("ios_object_count"), value: String((key.effectiveNumberIDs ?? key.numberIDs).count))
                    if let message = model.ownerKeyMessages[keyID] { Text(ProductText.systemMessage(message)).foregroundStyle(Brand.secondaryInk) }
                    if let owner, let bundle = try? key.bundle(masterKey: owner.masterKey), let rows = bundle["ble"] as? [[String: Any]], !rows.isEmpty {
                        ForEach(rows.compactMap { try? BLEGuestGrant(row: $0) }, id: \.objectID) { grant in
                            KeyValueRow(title: ProductText.string("ios_ble_pass"), value: ProductText.date(Date(timeIntervalSince1970: Double(grant.validUntil))))
                        }
                        Text(ProductText.string("ios_ble_revoke_delivery_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                    }
                }
                if let link {
                    Section {
                        InviteQRCode(text: link.absoluteString).frame(maxWidth: .infinity).padding(.vertical, 12)
                        ShareLink(item: link) { Label(ProductText.string("ios_share_guest_link"), systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryActionStyle())
                        Text(link.absoluteString).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                    } footer: { Text(ProductText.string("ios_key_single_recipient_hint")) }
                }
                Section {
                    if key.accessNeedsReview == true {
                        Text(ProductText.string("ios_key_recovered_rules_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                        Button(ProductText.string("ios_check_delegation_rules")) { reviewingRestoredAccess = true; editing = true }.buttonStyle(SecondaryActionStyle())
                            .disabled(key.pending != nil)
                    }
                    if key.pending != nil {
                        Button(ProductText.string("ios_check_result")) { Task { await model.refreshOwners() } }.buttonStyle(SecondaryActionStyle())
                        if model.canSaveOwnerKeyResult(keyID) {
                            Button(ProductText.string("ios_save_result")) { Task { await model.retrySavingOwnerKeyResult(server: server, keyID: keyID) } }.buttonStyle(PrimaryActionStyle())
                        } else if !key.sent {
                            Button(ProductText.string("ios_request_retry")) { Task { await model.retryPreparedOwnerKey(server: server, keyID: keyID) } }.buttonStyle(PrimaryActionStyle())
                            if key.keyID == nil {
                                Button(ProductText.string("ios_issue_cancel"), role: .destructive) { model.discardUnsentOwnerKey(server: server, keyID: keyID); if self.key == nil { dismiss() } }.buttonStyle(SecondaryActionStyle())
                            }
                        }
                    } else if key.state == .active || key.state == .paused {
                        Button(key.state == .paused ? ProductText.string("ios_access_resume") : ProductText.string("ios_access_pause")) { Task { await model.setOwnerKeyMode(server: server, keyID: keyID, paused: key.state != .paused) } }.buttonStyle(SecondaryActionStyle())
                    }
                    if key.pending == nil, key.state == .active, let owner,
                       let bundle = try? key.bundle(masterKey: owner.masterKey), let rows = bundle["ble"] as? [[String: Any]], !rows.isEmpty {
                        Button(ProductText.string("ios_ble_passes_renew")) { renewingBLE = true }.buttonStyle(SecondaryActionStyle())
                    }
                    if key.pending == nil && [.active, .paused, .restricted].contains(key.state) {
                        Button(ProductText.string("ios_message_compose")) { composing = true }.buttonStyle(SecondaryActionStyle())
                    }
                    if key.keyID != nil && key.state != .revoked { Button(ProductText.string("ios_key_revoke"), role: .destructive) { revoking = true }.buttonStyle(SecondaryActionStyle()) }
                }.disabled(model.ownerBusy)
            }
        }
        .navigationTitle(ProductText.string("ios_key_issued")).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $composing) { ComposeMessageScreen(manager: model.messages, target: .owner(server: server, keyID: keyID)) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let key, key.pending == nil, key.state == .active || key.state == .paused {
                    Button(ProductText.string("btn_edit")) { reviewingRestoredAccess = false; editing = true }.disabled(model.ownerBusy)
                }
            }
        }
        .sheet(isPresented: $editing) { IssueOwnerKeyScreen(serverPreset: server, editingKeyID: keyID, editAccessOnLaunch: reviewingRestoredAccess) }
        .task { if showRevokeOnLaunch { revoking = true } }
        .appConfirmationDialog(ProductText.string("ios_ble_passes_renew_title"),message:ProductText.string("ios_ble_passes_renew_body"),actionTitle:ProductText.string("ios_renew"),isPresented:$renewingBLE) {
            Task { await model.renewOwnerBLEKey(server: server, keyID: keyID) }
        }
        .appConfirmationDialog(ProductText.string("ios_key_revoke_title"),message:ProductText.string("ios_key_revoke_chain_hint"),actionTitle:ProductText.string("ios_key_revoke"),destructive:true,isPresented:$revoking) {
            Task { await model.revokeOwnerKey(server: server, keyID: keyID) }
        }
    }
}

struct InviteQRCode: View {
    let text: String
    var body: some View {
        if let image {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel(ProductText.string("ios_guest_key_qr"))
        }
    }
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }
}
