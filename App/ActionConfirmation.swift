import SwiftUI

/// This sheet confirms a card action; it is not an object-inspection destination.
struct ActionConfirmation: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let intent: ActionIntent
    @State private var code = ""
    @State private var repeatedCode = ""
    @State private var working = false
    @State private var message: String?
    @State private var configured = false
    @FocusState private var codeFocused: Bool

    private var needsSetup: Bool { intent.policy.authentication != nil && !model.hasActionCode && !configured }
    private var allowsPIN: Bool { intent.policy.authentication == "pin" || intent.policy.authentication == "either" }
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(intent.object.label).font(.title2.bold()).foregroundStyle(Brand.ink)
                if needsSetup {
                    Text("Создайте код Entrixy из 4–8 цифр. Это код приложения; он хранится только на этом iPhone.")
                    SecureField("Новый код", text: $code).keyboardType(.numberPad).textContentType(.newPassword)
                        .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    SecureField("Повторите код", text: $repeatedCode).keyboardType(.numberPad)
                        .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    Button("Сохранить код") { setup() }.buttonStyle(PrimaryActionStyle())
                        .disabled(working || code != repeatedCode || !(4...8).contains(code.count))
                } else if intent.policy.authentication != nil {
                    Text("Подтвердите действие способом, заданным владельцем.")
                    if allowsPIN {
                        SecureField("Код Entrixy", text: $code).keyboardType(.numberPad).textContentType(.password).focused($codeFocused)
                            .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        Button(intent.title) { authenticatePIN() }.buttonStyle(PrimaryActionStyle())
                            .disabled(working || !(4...8).contains(code.count))
                    }
                    if intent.policy.authentication != "pin" {
                        Button("Подтвердить биометрией") { authenticateBio() }.buttonStyle(PrimaryActionStyle()).disabled(working)
                    }
                } else {
                    Text("\(intent.title) объект?")
                    Button(intent.title) {
                        working = true
                        Task { await model.execute(intent); dismiss() }
                    }.buttonStyle(PrimaryActionStyle()).disabled(working)
                }
                if let message { Text(message).font(.subheadline).foregroundStyle(.red) }
                if working { ProgressView() }
                Spacer()
            }.padding(24)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(needsSetup ? "Код Entrixy" : "Подтверждение").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(working) } }
        }.interactiveDismissDisabled(working)
            .task {
                #if DEBUG && targetEnvironment(simulator)
                if ActionCaptureScenario.current == .codeEntry {
                    code = "1234"
                    codeFocused = true
                } else if ActionCaptureScenario.current == .codeRejected {
                    code = "0000"
                    authenticatePIN()
                }
                #endif
            }
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
                if try await model.authorizeCode(code, intent: intent) { await model.execute(intent); dismiss() }
                else { message = "Код не принят или ввод временно заблокирован. После нескольких ошибок нужно подождать." }
            } catch { message = "Не удалось проверить код в защищённом хранилище." }
        }
    }
    private func authenticateBio() {
        guard !working else { return }; working = true; message = nil
        Task {
            defer { working = false }
            do { try await model.authorizeBiometric(intent); await model.execute(intent); dismiss() }
            catch { message = "Биометрия недоступна или подтверждение отменено. Действие не отправлено." }
        }
    }
}
