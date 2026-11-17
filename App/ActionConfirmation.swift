import SwiftUI
import EntrixyCore

/// One frozen card intent, presented over the current root like Android CodeGate.
enum ActionPrompt: Identifiable {
    case guest(ActionIntent)
    case owner(OwnerActionIntent)
    var id: UUID { switch self { case .guest(let value): return value.id; case .owner(let value): return value.id } }
    var target: ObjectReference {
        switch self {
        case .guest(let value): return .received(guestID:value.guestID,objectID:value.object.id)
        case .owner(let value): return .owned(server:value.server,objectID:value.object.id)
        }
    }
    var automatic: Bool { switch self { case .guest(let value): return value.automatic; case .owner(let value): return value.automatic } }
}

struct ActionConfirmation: View {
    @EnvironmentObject private var model: AppModel
    let request: ActionPrompt
    private var guestIntent: ActionIntent? { if case .guest(let value) = request { return value }; return nil }
    private var ownerIntent: OwnerActionIntent? { if case .owner(let value) = request { return value }; return nil }
    private var authentication: String? { guestIntent?.policy.authentication ?? ownerIntent?.policy.authentication }
    private var title: String { guestIntent?.title ?? ownerIntent?.title ?? "Подтвердить" }
    private var objectLabel: String {
        if let intent = guestIntent, let entry = model.catalogObject(.received(guestID:intent.guestID,objectID:intent.object.id)) { return model.objectLabel(entry) }
        return guestIntent?.object.label ?? ownerIntent?.label ?? "Объект"
    }
    @State private var code = ""
    @State private var repeatedCode = ""
    @State private var working = false
    @State private var message: String?
    @State private var configured = false
    @FocusState private var codeFocused: Bool

    private var needsSetup: Bool { authentication != nil && !model.hasActionCode && !configured }
    private var allowsPIN: Bool { authentication == "pin" || authentication == "either" }
    private var isCurrent: Bool { model.actionPrompt?.id == request.id && model.canManageGuestAccess }
    var body: some View {
        AppDialogSurface {
            VStack(alignment: .leading, spacing: 16) {
                Text(needsSetup ? ProductText.string("code_title") : objectLabel)
                    .font(.title3.bold()).foregroundStyle(Brand.ink).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("action-confirmation-title")
                if needsSetup {
                    Text(ProductText.string("code_setup_hint")).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    field(ProductText.string("code_field"),text:$code)
                    field(ProductText.string("code_field_repeat"),text:$repeatedCode)
                    Text(ProductText.string("code_forgot_warning")).font(.footnote).foregroundStyle(AppPalette.destructive)
                } else if authentication != nil {
                    if allowsPIN { field(ProductText.string("code_field"),text:$code) }
                    if authentication != "pin" {
                        Button(ProductText.string("auth_use_biometric")) { authenticateBio() }
                            .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("action-confirmation-biometric")
                    }
                } else {
                    Text(ProductText.string("automation_confirm_hint_guest")).font(.body)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(AppPalette.destructive) }
                HStack(spacing:12) {
                    Button(ProductText.string("btn_cancel")) { close() }.buttonStyle(SecondaryActionStyle())
                    if needsSetup || authentication == nil || allowsPIN {
                        Button { submit() } label: {
                            ActionButtonLabel(title:needsSetup ? ProductText.string("btn_save") : title,busy:working)
                        }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("action-confirmation-submit")
                            .disabled((needsSetup || allowsPIN) && (!(4...8).contains(code.count) || (needsSetup && code != repeatedCode)))
                    }
                }
            }.disabled(working || !isCurrent)
        }
            .task {
                AppSoundCenter.shared.play(.confirm)
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
            .onDisappear { code = ""; repeatedCode = "" }
    }
    private func field(_ title: String,text: Binding<String>) -> some View {
        AppField(title) {
            SecureField(title,text:text).keyboardType(.numberPad).textContentType(.password).focused($codeFocused)
                .padding(14).background(Color(uiColor:.tertiarySystemFill),in:RoundedRectangle(cornerRadius:12))
                .onChange(of:text.wrappedValue) { text.wrappedValue = String($0.filter { $0.isASCII && $0.isNumber }.prefix(8)) }
        }
    }
    private func close() {
        code = ""; repeatedCode = ""; codeFocused = false
        model.dismissActionPrompt(request.id)
    }
    private func submit() {
        guard isCurrent, !working else { return }
        if needsSetup { setup() }
        else if authentication != nil { authenticatePIN() }
        else {
            working = true
            Task { await perform(); close(); working = false }
        }
    }
    private func perform() async {
        guard isCurrent else { return }
        await model.executeActionPrompt(request)
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
        guard isCurrent, !working else { return }; working = true; message = nil
        Task {
            defer { working = false; code = ""; repeatedCode = "" }
            do { try await model.setActionCode(code); configured = true }
            catch { message = "Не удалось сохранить код. Введите от 4 до 8 цифр." }
        }
    }
    private func authenticatePIN() {
        guard isCurrent, !working else { return }; working = true; message = nil
        Task {
            defer { working = false; code = "" }
            do {
                if try await authorizeCode() { await perform(); close() }
                else { message = "Код не принят или ввод временно заблокирован. После нескольких ошибок нужно подождать." }
            } catch { message = "Не удалось проверить код в защищённом хранилище." }
        }
    }
    private func authenticateBio() {
        guard isCurrent, !working else { return }; working = true; message = nil
        Task {
            defer { working = false }
            do { try await authorizeBiometric(); await perform(); close() }
            catch { message = "Биометрия недоступна или подтверждение отменено. Действие не отправлено." }
        }
    }
}
