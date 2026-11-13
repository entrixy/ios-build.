import SwiftUI
import PhotosUI
import EntrixyCore

struct KeyImportScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var input: String
    var delegationManager: DelegationInbox? = nil
    @State private var scanning = false
    @State private var photo: PhotosPickerItem?
    @State private var readingPhoto = false
    @State private var importError: String?
    private var delegation: DelegationLink? { try? DelegationLink.parse(input) }
    private var invite: GuestInvite? { try? GuestInvite.parse(input) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Вставьте ссылку от владельца или добавьте ключ с помощью QR-кода.")
                        .font(.body).foregroundStyle(Brand.secondaryInk).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ключ доступа").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
                        TextField("Ссылка или ключ", text: $input, axis: .vertical)
                            .lineLimit(3...4).padding(16).foregroundStyle(Brand.ink)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 1))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("inviteInput")
                        if let invite { Text("Сервер: \(invite.server)").font(.subheadline).foregroundStyle(Brand.secondaryInk) }
                    }
                    if delegation == nil {
                    VStack(spacing: 0) {
                        Button {
                            guard let value = UIPasteboard.general.string, !value.isEmpty else {
                                importError = "В буфере обмена нет ссылки на ключ."; return
                            }
                            accept(value)
                        } label: { ImportMethodRow(symbol: "doc.on.clipboard", title: "Вставить ссылку") }
                        Divider().padding(.leading, 52)
                        Button { scanning = true } label: { ImportMethodRow(symbol: "qrcode.viewfinder", title: "Сканировать QR-код") }
                        Divider().padding(.leading, 52)
                        PhotosPicker(selection: $photo, matching: .images) {
                            ImportMethodRow(symbol: "photo", title: readingPhoto ? "Читаем QR-код…" : "Выбрать QR-код из фото")
                        }.disabled(readingPhoto)
                    }
                    .buttonStyle(.plain).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if let importError { Text(importError).font(.subheadline).foregroundStyle(Color(uiColor: .systemRed)) }
                    if delegation != nil { DelegationImportSection(manager: delegationManager ?? model.delegationInbox, input: input) }
                    else {
                    Button {
                        Task {
                            if await model.add(input) { input = ""; dismiss() }
                            else { importError = model.errorMessage; model.errorMessage = nil }
                        }
                    } label: {
                        ActionButtonLabel(title: "Добавить ключ", busy: model.busy)
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(invite == nil || model.busy || readingPhoto)
                    }
                }.padding(DesignMetrics.pageInset)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Добавить ключ").navigationBarTitleDisplayMode(.inline)
            .sheetDismissFooter(disabled: model.busy || readingPhoto) { dismiss() }
            .sheet(isPresented: $scanning) { QRScannerScreen { value in accept(value); scanning = false } }
            .onChange(of: photo) { value in
                guard let value else { return }
                readingPhoto = true
                importError = nil
                Task {
                    defer { readingPhoto = false; photo = nil }
                    do {
                        guard let bytes = try await value.loadTransferable(type: Data.self), bytes.count <= 20_000_000 else {
                            throw QRPhotoReader.Failure.noCode
                        }
                        accept(try await QRPhotoReader.read(bytes))
                    } catch { importError = "Не удалось найти гостевой ключ в QR-коде на фотографии." }
                }
            }
        }.tint(Brand.ink)

    }

    private func accept(_ value: String) {
        do { input = try AccessLink.incomingText(value); importError = nil }
        catch { importError = "Вставьте полную ссылку или QR-код гостевого ключа Entrixy." }
    }
}

private struct ImportMethodRow: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 24)
            Text(title).font(.body)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(Brand.secondaryInk)
        }
        .foregroundStyle(Brand.ink).padding(.horizontal, 16).frame(minHeight: 54).contentShape(Rectangle())
    }
}
