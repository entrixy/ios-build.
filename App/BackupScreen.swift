import SwiftUI
import UniformTypeIdentifiers
import EntrixyCore

private extension UTType {
    static let entrixyIOSBackup = UTType(exportedAs: "com.entrixy.ios.backup", conformingTo: .data)
}
private struct EncryptedBackupDocument: FileDocument {
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
    @ObservedObject var manager: BackupManager
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var importPassword = ""
    @State private var importedBytes: Data?
    @State private var importing = false
    @State private var exporting = false
    @State private var confirming = false
    @State private var fileSaved = false
    var body: some View {
        List {
            if let message = manager.message { Section { Text(message).foregroundStyle(Brand.secondaryInk) } }
            if manager.hasPendingRestore {
                Section {
                    Text("Перенос не завершён").font(.headline)
                    Text("Осталось серверов: \(manager.remainingOwners), полученных ключей: \(manager.remainingGuests).")
                    Button("Продолжить перенос") { Task { await manager.restore() } }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy)
                } footer: { Text("Уже перенесённые доступы сохранены. План хранится на этом iPhone и не создаёт новую идентичность при повторе.") }
            } else {
                Section {
                    AppField("Пароль копии") {
                        SecureField("Пароль копии", text: $password).textContentType(.newPassword).disabled(manager.busy)
                    }
                    AppField("Повторите пароль") {
                        SecureField("Повторите пароль", text: $repeatedPassword).textContentType(.newPassword).disabled(manager.busy)
                    }
                    Button {
                        Task { do { _ = try await manager.export(password: password); fileSaved = false } catch { manager.report(error) } }
                    } label: { ActionButtonLabel(title: manager.exportData == nil ? "Создать зашифрованную копию" : "Копия создана", busy: manager.busy) }
                        .buttonStyle(PrimaryActionStyle()).disabled(manager.busy || manager.exportData != nil || password.count < 8 || password != repeatedPassword)
                    if manager.exportData != nil {
                        Text(fileSaved ? "Копия сохранена" : "Копия зашифрована и готова к сохранению").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                        Button("Сохранить в Файлы") { exporting = true }.buttonStyle(PrimaryActionStyle())
                    }
                } header: { Text("Сохранить доступы") }
                footer: { Text("Пароль не сохраняется в приложении. Без него расшифровать файл невозможно. Копия содержит состояние на момент создания; повторяйте её после изменения доступов.") }
                Section {
                    Button("Выбрать файл копии") { importing = true }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy)
                    if importedBytes != nil {
                        AppField("Пароль выбранного файла") {
                            SecureField("Пароль выбранного файла", text: $importPassword).disabled(manager.busy)
                        }
                        Button("Проверить копию") {
                            guard let bytes = importedBytes else { return }
                            Task { do { try await manager.inspect(bytes, password: importPassword) } catch { manager.report(error) } }
                        }.buttonStyle(SecondaryActionStyle()).disabled(manager.busy || importPassword.isEmpty)
                    }
                } header: { Text("Восстановить доступы") }
                if let preview = manager.preview {
                    Section {
                        KeyValueRow(title: "Копия создана", value: preview.created.formatted(date: .abbreviated, time: .shortened))
                        KeyValueRow(title: "Своих серверов", value: String(preview.owners.count))
                        KeyValueRow(title: "Полученных ключей", value: String(preview.guests.count))
                        ForEach(preview.owners) { Text($0.server).font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                        Button("Перенести доступы на этот iPhone") { confirming = true }.buttonStyle(PrimaryActionStyle()).disabled(manager.busy)
                    } header: { Text("Файл проверен") }
                    footer: { Text("Привязки переносятся через серверы. На прежнем телефоне перенесённые доступы прекратят работать. Локальный код и биометрия другого устройства не копируются.") }
                }
            }
        }
        .navigationTitle("Резервная копия").navigationBarTitleDisplayMode(.inline)
        .onChange(of: password) { _ in manager.clearExport(); fileSaved = false }
        .onChange(of: repeatedPassword) { _ in manager.clearExport(); fileSaved = false }
        .onChange(of: importPassword) { _ in manager.clearPreview() }
        .task { manager.updateProgress() }
        .fileExporter(isPresented: $exporting, document: manager.exportData.map { EncryptedBackupDocument(bytes: $0) }, contentType: .entrixyIOSBackup, defaultFilename: "Entrixy-iOS-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).eib") { result in
            if case .success = result { fileSaved = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.entrixyIOSBackup, .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > BackupEnvelope.maxPayloadSize + 58 { throw BackupFailure.invalidPayload }
                manager.clearPreview()
                importedBytes = try Data(contentsOf: url, options: .mappedIfSafe)
                importPassword = ""
            } catch { manager.report(error) }
        }
        .confirmationDialog("Перенести доступы? Перенесённые привязки на прежнем телефоне перестанут работать.", isPresented: $confirming, titleVisibility: .visible) {
            Button("Перенести на этот iPhone") { Task { await manager.restore() } }
        }
    }
}
