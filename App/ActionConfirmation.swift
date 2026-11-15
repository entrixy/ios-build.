import SwiftUI

/// This sheet confirms a card action; it is not an object-inspection destination.
struct ActionConfirmation: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let guestIntent: ActionIntent?
    private let ownerIntent: OwnerActionIntent?
    init(intent: ActionIntent) { guestIntent = intent; ownerIntent = nil }
    init(ownerIntent: OwnerActionIntent) { self.ownerIntent = ownerIntent; guestIntent = nil }
    private var authentication: String? { guestIntent?.policy.authentication ?? ownerIntent?.policy.authentication }
    private var title: String { guestIntent?.title ?? ownerIntent?.title ?? "Подтвердить" }
    private var objectLabel: String { guestIntent?.object.label ?? ownerIntent?.label ?? "Объект" }
    @State private var code = ""
    @State private var repeatedCode = ""
    @State private var working = false
    @State private var message: String?
    @State private var configured = false
    @FocusState private var codeFocused: Bool

    private var needsSetup: Bool { authentication != nil && !model.hasActionCode && !configured }
    private var allowsPIN: Bool { authentication == "pin" || authentication == "either" }
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(objectLabel).font(.title2.bold()).foregroundStyle(Brand.ink)
                if needsSetup {
                    Text("Создайте PIN-код приложения из 4–8 цифр. Он хранится только на этом iPhone и подтверждает действия с объектами.")
                    AppField("Новый PIN-код") {
                        SecureField("Новый PIN-код", text: $code).keyboardType(.numberPad).textContentType(.newPassword)
                            .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    AppField("Повторите PIN-код") {
                        SecureField("Повторите PIN-код", text: $repeatedCode).keyboardType(.numberPad)
                            .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button("Сохранить PIN-код") { setup() }.buttonStyle(PrimaryActionStyle())
                        .disabled(working || code != repeatedCode || !(4...8).contains(code.count))
                } else if authentication != nil {
                    Text("Подтвердите действие способом, заданным владельцем.")
                    if allowsPIN {
                        AppField("PIN-код приложения") {
                            SecureField("PIN-код приложения", text: $code).keyboardType(.numberPad).textContentType(.password).focused($codeFocused)
                                .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Button(title) { authenticatePIN() }.buttonStyle(PrimaryActionStyle())
                            .disabled(working || !(4...8).contains(code.count))
                    }
                    if authentication != "pin" {
                        Button("Подтвердить биометрией") { authenticateBio() }.buttonStyle(PrimaryActionStyle()).disabled(working)
                    }
                } else {
                    Text(title == "Позвонить" ? "Подтвердить звонок?" : "\(title) объект?")
                    Button(title) {
                        working = true
                        Task { await perform(); dismiss() }
                    }.buttonStyle(PrimaryActionStyle()).disabled(working)
                }
                if let message { Text(message).font(.subheadline).foregroundStyle(.red) }
                if working { ProgressView() }
                Spacer()
            }.padding(DesignMetrics.pageInset)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(needsSetup ? "Создать PIN-код" : "Подтвердить действие").navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(disabled: working) { dismiss() }
        }
            .task {
                #if DEBUG && targetEnvironment(simulator)
                if ActionCaptureScenario.current == .codeEntry {
                    code = "1234"
                    // Focus after the sheet has entered the window hierarchy.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    codeFocused = true
                } else if ActionCaptureScenario.current == .codeRejected {
                    code = "0000"
                    authenticatePIN()
                }
                #endif
            }
    }
    private func perform() async {
        if let guestIntent { await model.execute(guestIntent) }
        else if let ownerIntent { await model.execute(ownerIntent) }
    }
    private func authorizeCode() async throws -> Bool {
        if let guestIntent { return try await model.authorizeCode(code, intent: guestIntent) }
        if let ownerIntent { return try await model.authorizeCode(code, ownerIntent: ownerIntent) }
        return false
    }
    private func authorizeBiometric() async throws {
        if let guestIntent { try await model.authorizeBiometric(guestIntent) }
        else if let ownerIntent { try await model.authorizeBiometric(ownerIntent) }
    }
    private func setup() {
        guard !working else { return }; working = true; message = nil
        Task {
            defer { working = false; code = ""; repeatedCode = "" }
            do { try await model.setActionCode(code); configured = true }
            catch { message = "Не удалось сохранить код. Введите от 4 до 8 цифр." }
        }
    }
    private func authenticatePIN() {
        guard !working else { return }; working = true; message = nil
        Task {
            defer { working = false; code = "" }
            do {
                if try await authorizeCode() { await perform(); dismiss() }
                else { message = "Код не принят или ввод временно заблокирован. После нескольких ошибок нужно подождать." }
            } catch { message = "Не удалось проверить код в защищённом хранилище." }
        }
    }
    private func authenticateBio() {
        guard !working else { return }; working = true; message = nil
        Task {
            defer { working = false }
            do { try await authorizeBiometric(); await perform(); dismiss() }
            catch { message = "Биометрия недоступна или подтверждение отменено. Действие не отправлено." }
        }
    }
}
