import SwiftUI

struct AppEntryLockScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var code = ""
    @State private var working = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(Brand.ink).accessibilityHidden(true)
                Text("Введите код Entrixy").font(.title2.bold()).foregroundStyle(Brand.ink)
                Text("Код приложения отличается от кода блокировки iPhone.").foregroundStyle(Brand.secondaryInk)
                AppField("PIN-код Entrixy") {
                    SecureField("PIN-код Entrixy", text: $code).keyboardType(.numberPad)
                        .textContentType(.password).padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { unlock() } label: { ActionButtonLabel(title: "Войти", busy: working) }
                    .buttonStyle(PrimaryActionStyle()).disabled(working || !model.storageReady || !(4...8).contains(code.count))
                if model.appEntryBiometricEnabled {
                    Button("Войти с биометрией") { unlock(biometric: true) }
                        .buttonStyle(SecondaryActionStyle()).disabled(working || !model.storageReady)
                }
                if let message { Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if !model.storageReady, let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(DesignMetrics.pageInset)
            }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(ProductText.string("code_bio_title")).navigationBarTitleDisplayMode(.inline)
        }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ActionCaptureScenario.current == .appEntryRejected { code = "0000"; unlock() }
            #endif
        }
    }
    private func unlock(biometric: Bool = false) {
        guard !working else { return }; working = true; message = nil
        Task {
            defer { working = false; code = "" }
            do {
                if biometric { try await model.unlockApplicationWithBiometrics() }
                else {
                    let accepted = try await model.unlockApplication(code: code)
                    if !accepted { message = "Код не принят или ввод временно заблокирован. После нескольких ошибок нужно подождать." }
                }
            } catch { message = "Не удалось подтвердить вход. Код и доступы не изменялись." }
        }
    }
}

struct AppEntryLockSettings: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List { AppCodeSettingsSection() }.compactListSections()
            .navigationTitle(ProductText.string("code_title")).navigationBarTitleDisplayMode(.inline)
            .task {
                #if DEBUG && targetEnvironment(simulator)
                if ActionCaptureScenario.current == .appCodeSetup, !model.hasActionCode { model.codePrompt = AppCodePrompt(action:.setup(enableLock:false)) }
                #endif
            }
    }
}
