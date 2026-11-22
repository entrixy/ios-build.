import SwiftUI
import UIKit
import UniformTypeIdentifiers
import EntrixyCore

struct BackupShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor final class BackupPresentation: ObservableObject {
    enum Prompt { case export, password, review, result }
    @Published var prompt: Prompt? { didSet { updateVisibility() } }
    @Published private(set) var working = false { didSet { updateVisibility() } }
    @Published var password = ""
    @Published var repeated = ""
    @Published var importing = false
    @Published var exporting = false
    @Published var sharing: BackupShareFile?
    @Published private(set) var feedback: String?
    @Published private(set) var progress = "backup_checking"
    let manager: BackupManager
    private unowned let app: AppModel
    private var imported: Data?
    private var operation = UUID()
    private var exportedMaterial = Set<String>()
    private var sharedURL: URL?
    init(app: AppModel, manager: BackupManager) { self.app = app; self.manager = manager }
    private func updateVisibility() { app.backupPromptPending = prompt != nil || working }
    func beginExport() {
        guard !working, app.canManageGuestAccess else { return }
        password = ""; repeated = ""; feedback = nil; manager.clearPreview(); manager.clearExport(); prompt = .export
    }
    func beginImport() { guard !working, app.canManageGuestAccess else { return }; feedback = nil; manager.clearPreview(); importing = true }
    func cancel() {
        operation = UUID(); password = ""; repeated = ""; imported = nil; prompt = nil
        manager.clearPreview()
        if !working && !exporting && sharing == nil { manager.clearExport() }
    }
    func prepareExport(send: Bool) async {
        guard !working, password.count >= 8, password == repeated, app.canManageGuestAccess else { return }
        let token = operation, secret = password
        working = true; progress = "backup_create"; feedback = nil
        defer { working = false; password = ""; repeated = "" }
        do {
            let data = try await manager.export(password:secret)
            guard token == operation, app.canManageGuestAccess else { manager.clearExport(); return }
            exportedMaterial = manager.exportMaterialIDs
            prompt = nil
            if send {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Entrixy-" + UUID().uuidString + ".eib")
                try data.write(to:url,options:.atomic)
                sharedURL = url
                sharing = BackupShareFile(url:url)
            } else { exporting = true }
        } catch { manager.report(error); feedback = manager.message; if token == operation { prompt = .export } }
    }
    func acceptFile(_ result: Result<URL,Error>) async {
        guard !working else { return }
        let token = operation
        working = true; progress = "backup_checking"
        defer { working = false }
        do {
            let url = try result.get()
            let data = try await Task.detached(priority:.userInitiated) { try Self.readFile(url) }.value
            guard token == operation, app.canManageGuestAccess else { return }
            imported = data; password = ""; feedback = nil; prompt = .password
        } catch {
            if (error as NSError).code == NSUserCancelledError { return }
            manager.report(error); feedback = manager.message; if token == operation { prompt = .result }
        }
    }
    nonisolated static func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size > BackupEnvelope.maxPayloadSize + 58 { throw BackupFailure.invalidPayload }
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount:65536), !chunk.isEmpty {
            guard result.count + chunk.count <= BackupEnvelope.maxPayloadSize + 58 else { throw BackupFailure.invalidPayload }
            result.append(chunk)
        }
        guard !result.isEmpty else { throw BackupFailure.invalidPayload }
        return result
    }
    func inspect() async {
        guard !working, let imported, !password.isEmpty else { return }
        let token = operation, secret = password
        working = true; progress = "backup_checking"; feedback = nil
        defer { working = false; password = "" }
        do {
            try await manager.inspect(imported,password:secret)
            guard token == operation, app.canManageGuestAccess else { manager.clearPreview(); return }
            prompt = .review
        } catch { manager.report(error); feedback = manager.message; if token == operation { prompt = .password } }
    }
    func restore() async {
        guard !working else { return }
        let token = operation
        working = true; progress = "backup_restore"; prompt = nil
        await manager.restore()
        working = false
        if token == operation { feedback = manager.message; imported = nil; prompt = .result }
    }
    func didExport(_ result: Result<URL,Error>) {
        switch result {
        case .success: markDone(); feedback = ProductText.string("backup_done"); prompt = .result
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { manager.report(error); feedback = manager.message; prompt = .result }
        }
        manager.clearExport()
    }
    func didShare(_ completed: Bool) {
        if completed { markDone(); feedback = ProductText.string("backup_done"); prompt = .result }
    }
    func removeSharedFile() {
        if let url = sharedURL { try? FileManager.default.removeItem(at:url) }
        sharedURL = nil
        sharing = nil; manager.clearExport()
    }
    private func markDone() {
        UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:"entrixy.backup.at")
        UserDefaults.standard.set(Array(exportedMaterial),forKey:"entrixy.backup.material")
    }
}

/// A persistent root presenter keeps password/review dialogs over the whole
/// screen and attaches Files/Share to one host instead of individual list rows.
struct BackupFlowHost: View {
    @ObservedObject var flow: BackupPresentation
    @ObservedObject private var manager: BackupManager
    @FocusState private var focusedPassword:String?
    init(flow: BackupPresentation) { self.flow = flow; manager = flow.manager }
    var body: some View {
        ZStack {
            Color.clear.frame(width:0,height:0).allowsHitTesting(false).accessibilityHidden(true)
            if flow.working {
                AppDialogSurface { VStack(alignment:.leading,spacing:18) { Text(ProductText.string(flow.progress)).font(.title3.bold()); ProgressView().frame(maxWidth:.infinity) } }
            } else if let prompt = flow.prompt {
                AppDialogSurface {
                    VStack(alignment:.leading,spacing:16) {
                        Text(ProductText.string(promptTitle(prompt))).font(.title3.bold())
                        switch prompt {
                        case .export: exportFields
                        case .password: importFields
                        case .review: review
                        case .result: Text(ProductText.systemMessage(flow.feedback ?? ""))
                        }
                    }
                } footer: { promptActions(prompt) }
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).allowsHitTesting(flow.prompt != nil || flow.working)
        .fileImporter(isPresented:$flow.importing,allowedContentTypes:[.entrixyIOSBackup,.data]) { result in Task { await flow.acceptFile(result) } }
        .fileExporter(isPresented:$flow.exporting,document:manager.exportData.map { EncryptedBackupDocument(bytes:$0) },contentType:.entrixyIOSBackup,defaultFilename:"Entrixy-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).eib",onCompletion:flow.didExport)
        .sheet(item:$flow.sharing,onDismiss:flow.removeSharedFile) { item in BackupShareSheet(url:item.url,completion:flow.didShare) }
    }
    @ViewBuilder private func promptActions(_ prompt:BackupPresentation.Prompt) -> some View {
        switch prompt {
        case .export:
            VStack(spacing:12) {
                EqualActionRow {
                    Button { Task { await flow.prepareExport(send:false) } } label: {
                        Label(ProductText.string("ios_backup_save_file"),systemImage:"tray.and.arrow.down")
                    }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("backup-save-file")
                    Button { Task { await flow.prepareExport(send:true) } } label: {
                        Label(ProductText.string("ios_backup_share_file"),systemImage:"square.and.arrow.up")
                    }.buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("backup-share-file")
                }.disabled(flow.password.count < 8 || flow.password != flow.repeated)
                Button(ProductText.string("btn_cancel")) { flow.cancel() }.buttonStyle(SecondaryActionStyle())
            }
        case .password:
            EqualActionRow {
                Button(ProductText.string("btn_cancel")) { flow.cancel() }.buttonStyle(SecondaryActionStyle())
                Button(ProductText.string("ios_backup_check")) { Task { await flow.inspect() } }.buttonStyle(PrimaryActionStyle()).disabled(flow.password.isEmpty)
            }
        case .review:
            EqualActionRow {
                Button(ProductText.string("btn_cancel")) { flow.cancel() }.buttonStyle(SecondaryActionStyle())
                Button(ProductText.string("ios_backup_transfer")) { Task { await flow.restore() } }.buttonStyle(PrimaryActionStyle()).disabled(manager.preview == nil)
            }
        case .result:
            Button(ProductText.string("btn_ok")) { flow.cancel() }.buttonStyle(PrimaryActionStyle())
        }
    }
    private func promptTitle(_ prompt: BackupPresentation.Prompt) -> String {
        switch prompt { case .export,.result: return "backup_section"; case .password,.review: return "backup_restore" }
    }
    private func password(_ title: String,value: Binding<String>) -> some View {
        AppField(ProductText.string(title)) {
            SecureField(ProductText.string(title),text:value).textInputAutocapitalization(.never).autocorrectionDisabled().padding(14).background(Color(uiColor:.tertiarySystemFill),in:RoundedRectangle(cornerRadius:12))
                .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(flow.prompt == .export ? .newPassword : .password)
                .focused($focusedPassword,equals:title).submitLabel(.done).onSubmit { focusedPassword=nil }
        }
    }
    private var exportFields: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(ProductText.string("backup_pass_forgot")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            Text(ProductText.string("backup_send_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            password("backup_pass_label",value:$flow.password)
            password("backup_pass_repeat",value:$flow.repeated)
            if !flow.password.isEmpty, flow.password.count < 8 { Text(ProductText.string("backup_pass_short",8)).font(.footnote).foregroundStyle(AppPalette.destructive) }
            if !flow.repeated.isEmpty, flow.password != flow.repeated { Text(ProductText.string("backup_pass_mismatch")).font(.footnote).foregroundStyle(AppPalette.destructive) }
            if let feedback = flow.feedback { Text(ProductText.systemMessage(feedback)).font(.footnote).foregroundStyle(AppPalette.destructive) }
        }
    }
    private var importFields: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(ProductText.string("ios_backup_transfer_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            password("backup_pass_label",value:$flow.password)
            if let feedback = flow.feedback { Text(ProductText.systemMessage(feedback)).font(.footnote).foregroundStyle(AppPalette.destructive) }
        }
    }
    @ViewBuilder private var review: some View {
        if let preview = manager.preview {
            Text(ProductText.date(preview.created)).font(.footnote).foregroundStyle(Brand.secondaryInk)
            Text(ProductText.string("ios_backup_contents",preview.owners.count,preview.guests.count + (preview.androidGuests ?? []).count))
            Text(ProductText.string("ios_backup_transfer_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            if let sounds = preview.eventSounds, !sounds.unavailableSamples.isEmpty {
                Text(ProductText.string("ios_backup_missing_sounds",sounds.unavailableSamples.count)).font(.footnote).foregroundStyle(Brand.secondaryInk)
            }
        }
    }
}

private struct BackupShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems:[url],applicationActivities:nil)
        controller.completionWithItemsHandler = { _,completed,_,_ in Task { @MainActor in completion(completed) } }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController,context: Context) {}
}

extension SavedState {
    /// Android marks a backup stale when new key material appears, not on each
    /// journal entry, websocket snapshot or connection-status update.
    var backupMaterialIDs: Set<String> {
        var values = Set<String>()
        for owner in owners ?? [] {
            values.insert("owner:" + owner.server + ":" + GuestCrypto.hash(owner.masterKey + Data(((owner.credentials?.deviceID ?? "") + (owner.credentials?.deviceSecret ?? "")).utf8)))
            for object in owner.objects ?? [] {
                values.insert("object:" + owner.server + ":" + GuestCrypto.hash(Data((object.wrappedKey + (object.wrappedBLESecret ?? "") + (object.wrappedDeviceCredentials ?? "")).utf8)))
                if let rotation = object.keyRotation {
                    // Mark stale when the next key is prepared/shared, before
                    // its metadata acknowledgement. A backup made in flight
                    // already covers the committed key and needs no new prompt.
                    values.insert("object:" + owner.server + ":" + GuestCrypto.hash(Data((rotation.wrappedKey + (object.wrappedBLESecret ?? "") + (object.wrappedDeviceCredentials ?? "")).utf8)))
                }
            }
            for key in owner.issuedKeys ?? [] { values.insert("issued:" + owner.server + ":" + GuestCrypto.hash(Data(key.wrappedSecrets.utf8) + (key.company?.publicKey ?? Data()))) }
            for key in owner.androidKeys ?? [] { values.insert("android-key:" + owner.server + ":" + String(key.serverKeyID) + ":" + GuestCrypto.hash(Data(((key.userKey ?? "") + (key.wrappedBundleKey ?? "")).utf8))) }
        }
        for guest in guests { values.insert("guest:" + guest.id + ":" + GuestCrypto.hash(guest.invite.bundleKey)) }
        for guest in androidPendingGuests ?? [] { values.insert("pending:" + guest.id + ":" + GuestCrypto.hash(Data((guest.recipient?.privateKey ?? "").utf8))) }
        for access in passedAccess ?? [] { values.insert("passed:" + access.id.uuidString + ":" + GuestCrypto.hash(access.secret)) }
        return values
    }
}

struct BackupSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var flow: BackupPresentation
    @ObservedObject private var manager: BackupManager
    @AppStorage("entrixy.backup.at") private var backupAt = 0.0
    init(flow: BackupPresentation) { self.flow = flow; manager = flow.manager }
    private var stale: Bool {
        guard let state = try? app.backupState() else { return false }
        return !state.backupMaterialIDs.isSubset(of:Set(UserDefaults.standard.stringArray(forKey:"entrixy.backup.material") ?? []))
    }
    var body: some View {
        Group {
            Section {
                Text(ProductText.string("backup_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                if backupAt == 0 || stale { Text(ProductText.string(backupAt == 0 ? "backup_never" : "backup_stale")).font(.footnote).foregroundStyle(Brand.secondaryInk) }
                Text(ProductText.string("backup_foreign_note")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                if manager.hasPendingRestore {
                    Text(ProductText.string("ios_backup_remaining",manager.remainingOwners,manager.remainingGuests)).font(.subheadline)
                }
            } header: { Text(ProductText.string("backup_section")) }
            Section {
                if manager.hasPendingRestore {
                    Button(ProductText.string("ios_backup_continue")) { Task { await flow.restore() } }.buttonStyle(PrimaryActionStyle()).actionListRow()
                } else {
                    EqualActionRow {
                        Button(ProductText.string("backup_create")) { flow.beginExport() }.buttonStyle(PrimaryActionStyle())
                        Button(ProductText.string("backup_restore")) { flow.beginImport() }.buttonStyle(SecondaryActionStyle())
                    }.actionListRow()
                }
            }.disabled(flow.working || manager.busy || !app.storageReady)
        }
    }
}
