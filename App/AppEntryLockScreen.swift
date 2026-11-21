import SwiftUI

struct AppEntryLockScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var code = ""
    @State private var working = false
    @State private var message: String?
    @State private var reset = false
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(Brand.ink).accessibilityHidden(true)
                Text(ProductText.string("ios_entry_title")).font(.title2.bold()).foregroundStyle(Brand.ink)
                Text(ProductText.string("ios_entry_code_hint")).foregroundStyle(Brand.secondaryInk)
                AppField(ProductText.string("code_field")) {
                    SecureField(ProductText.string("code_field"), text: $code).keyboardType(.numberPad)
                        .textContentType(.password).padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { unlock() } label: { ActionButtonLabel(title:ProductText.string("ios_entry_sign_in"), busy: working) }
                    .buttonStyle(PrimaryActionStyle()).disabled(working || !model.storageReady || !(4...8).contains(code.count))
                if model.appEntryBiometricEnabled {
                    Button(ProductText.string("ios_entry_biometric")) { unlock(biometric: true) }
                        .buttonStyle(SecondaryActionStyle()).disabled(working || !model.storageReady)
                }
                Button(ProductText.string("ios_code_forgot")) { reset = true }
                    .buttonStyle(SecondaryActionStyle()).disabled(working || !model.storageReady)
                if let message { Text(ProductText.systemMessage(message)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if !model.storageReady, let error = model.errorMessage { Text(ProductText.systemMessage(error)).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(DesignMetrics.pageInset)
            }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(ProductText.string("code_bio_title")).navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented:$reset) { LocalResetScreen() }
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
                    if !accepted { message = ProductText.string("ios_entry_rejected") }
                }
            } catch { message = ProductText.string("ios_entry_failed") }
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
