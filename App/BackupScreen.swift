import SwiftUI
import UniformTypeIdentifiers
import EntrixyCore

extension UTType {
    static let entrixyIOSBackup = UTType(exportedAs: "com.entrixy.ios.backup", conformingTo: .data)
}
struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.entrixyIOSBackup, .data] }
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= BackupEnvelope.maxPayloadSize + 58 else { throw BackupFailure.invalidPayload }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}

struct BackupScreen: View {
    @StateObject private var flow: BackupPresentation
    @Environment(\.scenePhase) private var phase
    init(manager: BackupManager) { _flow = StateObject(wrappedValue:manager.makePresentation()) }
    var body: some View {
        List { BackupSettingsSection(flow:flow) }.compactListSections()
            .navigationTitle(ProductText.string("backup_section")).navigationBarTitleDisplayMode(.inline)
            .accessibilityHidden(flow.prompt != nil || flow.working)
            .overlay { BackupFlowHost(flow:flow) }
            .onChange(of:phase) { if $0 == .background { flow.cancel() } }
    }
}
