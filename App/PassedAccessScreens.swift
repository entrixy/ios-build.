import SwiftUI
import EntrixyCore

struct PassedAccessScreen: View {
    @EnvironmentObject private var app: AppModel
    var manager: PassManager? = nil
    var body: some View { PassedAccessContent(manager: manager ?? app.passManager) }
}
private struct PassedAccessContent: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: PassManager
    @State private var adding = false
    var body: some View {
        List {
            if let message = manager.message { Section { Text(ProductText.systemMessage(message)).foregroundStyle(Brand.secondaryInk) } }
            ForEach(app.passedAccess) { record in
                NavigationLink { PassedAccessDetail(manager: manager, accessID: record.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.label).font(.headline)
                        Text(passedAccessStatus(record)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    }.padding(.vertical, 5)
                }
            }
            if app.passedAccess.isEmpty { Text(ProductText.string("ios_passed_keys_empty")).foregroundStyle(Brand.secondaryInk) }
        }
        .navigationTitle(ProductText.string("ios_delegated_access")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus").accessibilityLabel(ProductText.string("ios_access_pass")) }.disabled(manager.busy || app.guests.isEmpty || app.busy || app.ownerBusy) } }
        .refreshable { await manager.reload() }
        .task { await manager.reload() }
        .sheet(isPresented: $adding) { PassAccessForm(manager: manager) }
    }
}
private struct PassObjectOption: Identifiable {
    let source: SavedGuest
    let object: GuestObject
    let allowance: PassAllowance
    let existing: Bool
    var id: String { source.id + "|" + object.id }
    var maximumDepth: Int { max(0,allowance.depth - 1) }
    var maximumPool: Int { max(1,allowance.poolLeft - (existing ? 0 : 1)) }
}
struct PassAccessForm: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: PassManager
    var accessID: UUID? = nil
    @State private var label = ""
    @State private var welcome = ""
    @State private var selected: [String:[Int:KeyObjectAccess]] = [:]
    @State private var editingAccess: PassObjectOption?
    @State private var loaded = false
    @State private var saving = false
    private var record: PassedAccess? { app.passedAccess.first { $0.id == accessID } }
    private var lockedHost: String? {
        record?.server ?? selected.keys.first.flatMap { id in app.guests.first { $0.id == id }?.invite.server }
    }
    private var options: [PassObjectOption] {
        var seen = Set<String>(), result: [PassObjectOption] = []
        for guest in app.guests {
            for object in guest.objects {
                let current = record?.parts.contains { $0.sourceID == guest.id && $0.objects[String(object.numberID)] != nil } == true
                guard let allow = manager.snapshots[guest.id]?.allowance[object.numberID], allow.depth > 0,
                      allow.poolLeft > 0 || current else { continue }
                let key = guest.invite.server + "|" + (object.kind == "ble" ? "b" : "n") + "|" + String(object.numberID)
                if seen.insert(key).inserted { result.append(PassObjectOption(source:guest,object:object,allowance:allow,existing:current)) }
            }
        }
        return result
    }
    private var hosts: [String] { var values: [String] = []; for option in options where !values.contains(option.source.invite.server) { values.append(option.source.invite.server) }; return values }
    private func value(_ option: PassObjectOption) -> KeyObjectAccess { selected[option.source.id]?[option.object.numberID] ?? (try! KeyObjectAccess(nativeOnly:option.allowance.nativeOnly,depth:0,pool:min(3,option.maximumPool))) }
    private func toggle(_ option: PassObjectOption) {
        guard !option.source.paused, lockedHost == nil || lockedHost == option.source.invite.server else { return }
        if selected[option.source.id]?[option.object.numberID] != nil {
            selected[option.source.id]?.removeValue(forKey:option.object.numberID)
            if selected[option.source.id]?.isEmpty == true { selected.removeValue(forKey:option.source.id) }
        } else { selected[option.source.id,default:[:]][option.object.numberID] = value(option) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppField(ProductText.string("guests_name_label")) {
                        TextField(ProductText.string("guests_default_name"),text:$label).textInputAutocapitalization(.words)
                            .onChange(of:label) { value in let normalized=String(value.replacingOccurrences(of:"\n",with:"").replacingOccurrences(of:"\r",with:"").prefix(128));if normalized != value { label=normalized } }
                    }
                    if accessID == nil { AppField(ProductText.string("guests_welcome_label")) { TextField(ProductText.string("guests_welcome_hint"),text:$welcome,axis:.vertical).lineLimit(2...5) } }
                }
                Section { Text(ProductText.string("guests_objects_allowed")).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                ForEach(hosts,id:\.self) { host in
                    Section {
                        ForEach(options.filter { $0.source.invite.server == host }) { option in row(option) }
                    } header: { if hosts.count > 1 { Text(host) } }
                }
                if let message = manager.message { Section { Text(ProductText.systemMessage(message)).font(.footnote).foregroundStyle(Brand.secondaryInk) } }
                if let record, record.parts.contains(where:{ $0.state == .draft }) {
                    Section { Button(ProductText.string("ios_transfer_continue")) { Task { await manager.continueCreating(record.id) } }.buttonStyle(SecondaryActionStyle()).actionListRow() }
                }
                Section {
                    Button { Task { await save() } } label: { ActionButtonLabel(title:ProductText.string(accessID == nil ? "delegate_create" : "btn_save"),busy:saving || manager.busy) }
                        .buttonStyle(PrimaryActionStyle()).actionListRow()
                        .disabled(selected.isEmpty || record?.parts.contains(where:{ $0.pendingEdit != nil || $0.state == .draft }) == true)
                }
            }.disabled(saving || manager.busy || app.busy || app.ownerBusy || !app.canManageGuestAccess)
                .taskSheetTitle(ProductText.string(accessID == nil ? "delegate_create" : "guests_access_title"),form:true)
                .sheetDismissFooter(disabled:saving || manager.busy) { dismiss() }
                .sheet(item:$editingAccess) { option in
                    GuestObjectAccessEditor(title:option.object.label,value:Binding(get:{ value(option) },set:{ selected[option.source.id,default:[:]][option.object.numberID] = $0 }),showNative:false,maxDepth:option.maximumDepth,maxPool:option.maximumPool)
                }
                .task {
                    if !loaded { loaded = true; if let record { label = record.label; for part in record.parts { selected[part.sourceID] = Dictionary(uniqueKeysWithValues:part.objects.compactMap { id,value in Int(id).map { ($0,value) } }) } } }
                    await manager.reload()
                }
        }
    }
    private func row(_ option: PassObjectOption) -> some View {
        let checked = selected[option.source.id]?[option.object.numberID] != nil
        let other = lockedHost != nil && lockedHost != option.source.invite.server
        return HStack(spacing:8) {
            Button { toggle(option) } label: {
                HStack(spacing:12) { Image(systemName:checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? AppPalette.selected : Brand.secondaryInk); Text(option.object.label).frame(maxWidth:.infinity,alignment:.leading) }
                    .foregroundStyle(other ? Brand.secondaryInk : Brand.ink).frame(minHeight:52).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(other || option.source.paused)
                .accessibilityIdentifier("pass-object-" + option.id)
            if checked {
                Button { editingAccess = option } label: { Image(systemName:"person.badge.key").resizable().scaledToFit().frame(width:24,height:24) }
                    .buttonStyle(SquareIconActionStyle()).accessibilityLabel(ProductText.string("guests_access_title"))
            }
        }
    }
    private func save() async {
        guard !saving, !selected.isEmpty else { return }; saving = true; defer { saving = false }
        let name = label.trimmingCharacters(in:.whitespacesAndNewlines)
        if let initial = record {
            let sources = Set(initial.parts.map(\.sourceID)).union(selected.keys)
            for source in sources.sorted() {
                let desired = selected[source] ?? [:]
                let current = app.passedAccess.first(where:{ $0.id == initial.id })?.parts.first(where:{ $0.sourceID == source })?.objects ?? [:]
                let encoded = Dictionary(uniqueKeysWithValues:desired.map { (String($0.key),$0.value) })
                if encoded != current, !(await manager.editObjects(initial.id,sourceID:source,numberIDs:Set(desired.keys),access:desired)) { return }
            }
            guard var latest = app.passedAccess.first(where:{ $0.id == initial.id }) else { return }
            latest.label = name.isEmpty ? ProductText.string("guests_default_name") : name
            do { try app.savePassedAccess(latest) } catch { app.errorMessage = ProductText.string("ios_guest_name_save_failed"); return }
            dismiss()
        } else if await manager.create(label:name.isEmpty ? ProductText.string("guests_default_name") : name,welcome:welcome.trimmingCharacters(in:.whitespacesAndNewlines),objects:selected) != nil { dismiss() }
    }
}
struct PassedAccessDetail: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: PassManager
    let accessID: UUID
    @State private var revoking = false
    @State private var composing = false
    @State private var editingSource: String?
    private var record: PassedAccess? { app.passedAccess.first { $0.id == accessID } }
    var body: some View {
        List {
            if let record {
                Section {
                    Text(record.label).font(.headline)
                    Text(passedAccessStatus(record)).foregroundStyle(Brand.secondaryInk)
                    KeyValueRow(title: ProductText.string("ble_server_label"), value: record.server)
                    KeyValueRow(title: ProductText.string("ios_source_keys"), value: String(record.parts.count))
                    if let message = manager.message { Text(ProductText.systemMessage(message)).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                }
                if let link = record.link, let url = URL(string: link.url) {
                    Section {
                        InviteQRCode(text: link.url).frame(maxWidth: .infinity).padding(.vertical, 12)
                        ShareLink(item: url) { Label(ProductText.string("ios_link_share"), systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryActionStyle())
                        Text(link.url).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                    } footer: { Text(ProductText.string("ios_pass_single_recipient_hint")) }
                }
                Section {
                    Button(ProductText.string("ios_refresh_data")) { Task { await manager.reload() } }.buttonStyle(SecondaryActionStyle())
                    if record.parts.contains(where: { $0.state == .draft }) {
                        Button(ProductText.string("ios_transfer_continue")) { Task { await manager.continueCreating(record.id) } }.buttonStyle(PrimaryActionStyle())
                    }
                    if record.parts.contains(where: { $0.childID != nil }) && record.link != nil {
                        Button(ProductText.string("ios_message_compose")) { composing = true }.buttonStyle(SecondaryActionStyle())
                    }
                    ForEach(record.parts.indices, id: \.self) { index in
                        let part = record.parts[index]
                        if ![PassedAccess.State.draft, .revoking, .revoked].contains(part.state) {
                            Button(ProductText.string("ios_edit_objects_part_fmt",index + 1)) { editingSource = part.sourceID }.buttonStyle(SecondaryActionStyle()).disabled(part.pendingEdit != nil)
                        }
                    }
                    if !record.parts.allSatisfy({ $0.state == .revoked }) {
                        Button(record.parts.contains(where: { $0.state == .revoking }) ? ProductText.string("ios_revoke_retry") : ProductText.string("ios_passed_access_revoke"), role: .destructive) { revoking = true }.buttonStyle(SecondaryActionStyle())
                    }
                }.disabled(manager.busy || app.busy || app.ownerBusy)
            }
        }
        .navigationTitle(ProductText.string("guests_key_delegated")).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $composing) { ComposeMessageScreen(manager: app.messages, target: .passed(accessID)) }
        .sheet(isPresented: Binding(get: { editingSource != nil }, set: { if !$0 { editingSource = nil } })) {
            if let source = editingSource { EditPassedObjects(manager: manager, accessID: accessID, sourceID: source) }
        }
        .appConfirmationDialog(ProductText.string("ios_access_revoke_title"),message:ProductText.string("ios_link_revoke_chain_hint"),actionTitle:ProductText.string("ios_access_revoke"),destructive:true,isPresented:$revoking) {
            Task { await manager.revoke(accessID, retry: true) }
        }
    }
}
func passedAccessStatus(_ record: PassedAccess) -> String {
    if record.parts.allSatisfy({ $0.state == .revoked }) { return ProductText.string("ios_access_revoked") }
    if record.parts.contains(where: { $0.state == .revoking }) { return ProductText.string("ios_revoke_incomplete") }
    if record.parts.contains(where: { $0.pendingEdit != nil }) { return ProductText.string("ios_object_changes_unconfirmed") }
    if record.parts.contains(where: { $0.state == .draft }) { return ProductText.string("ios_link_issuance_unconfirmed") }
    if record.parts.contains(where: { $0.state == .unavailable }) { return ProductText.string("ios_delegated_access_unconfirmed") }
    if record.parts.contains(where: { $0.state == .awaitingOwner }) { return ProductText.string("ios_owners_confirmation_pending") }
    if record.parts.allSatisfy({ $0.state == .active }) { return ProductText.string("ios_access_active") }
    return ProductText.string("ios_recipient_acceptance_pending")
}

struct EditPassedObjects: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: PassManager
    let accessID: UUID
    let sourceID: String
    @State private var selected = Set<Int>()
    @State private var loaded = false
    private var record: PassedAccess? { app.passedAccess.first { $0.id == accessID } }
    private var part: PassedAccess.Part? { record?.parts.first { $0.sourceID == sourceID } }
    private var guest: SavedGuest? { app.guests.first { $0.id == sourceID } }
    var body: some View {
        NavigationStack {
            Form {
                Section(ProductText.string("ios_recipient_objects")) {
                    ForEach(guest?.objects ?? []) { object in
                        let allow = manager.snapshots[sourceID]?.allowance[object.numberID]
                        let existing = part?.objects[String(object.numberID)] != nil
                        let canAdd = allow?.canPass == true || (existing && (allow?.depth ?? 0) > 0)
                        Button {
                            if selected.contains(object.numberID) { selected.remove(object.numberID) } else { selected.insert(object.numberID) }
                        } label: {
                            HStack { Text(object.label); Spacer(); Image(systemName: selected.contains(object.numberID) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(object.numberID) ? AppPalette.selected : Brand.secondaryInk) }.foregroundStyle(Brand.ink)
                        }.disabled(!selected.contains(object.numberID) && !canAdd)
                    }
                    if guest == nil { Text(ProductText.string("ios_source_key_removed")).foregroundStyle(Brand.secondaryInk) }
                }
                Section {
                    if let message = manager.message { Text(ProductText.systemMessage(message)).foregroundStyle(Brand.secondaryInk) }
                    Button(ProductText.string("ios_objects_save")) { Task { if await manager.editObjects(accessID, sourceID: sourceID, numberIDs: selected) { dismiss() } } }.buttonStyle(PrimaryActionStyle()).disabled(guest == nil)
                } footer: { Text(ProductText.string("ios_pass_object_changes_hint")) }
            }.disabled(manager.busy || app.busy || app.ownerBusy || part?.pendingEdit != nil)
            .taskSheetTitle(ProductText.string("ios_recipient_objects"),form:true)
            .sheetDismissFooter(disabled: manager.busy || app.busy || app.ownerBusy) { dismiss() }

            .task { if !loaded { loaded = true; selected = Set(part?.objects.keys.compactMap(Int.init) ?? []) }; await manager.reload(sourceID: sourceID) }
        }
    }
}
