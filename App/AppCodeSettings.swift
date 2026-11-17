import SwiftUI

struct AppCodePrompt: Identifiable {
    enum Action { case setup(enableLock: Bool), change, lock(Bool), biometric(Bool) }
    let id = UUID()
    let action: Action
}

/// SettingsScreen System / Code: changes take effect on the same controls as
/// Android. Protected transitions ask for the current code in a compact dialog.
struct AppCodeSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var working = false
    var body: some View {
        Group {
            Section { Text(ProductText.string("code_settings_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk) }
                header: { Text(ProductText.string("code_title")) }
            Section {
                Button(ProductText.string(model.hasActionCode ? "code_change" : "code_set")) {
                    model.codePrompt = AppCodePrompt(action:model.hasActionCode ? .change : .setup(enableLock:false))
                }.buttonStyle(SecondaryActionStyle()).actionListRow()
            }
            Section {
            Toggle(ProductText.string("app_lock_switch"),isOn:Binding(get:{ model.appLockEnabled },set:{ enabled in
                if !model.hasActionCode { model.codePrompt = AppCodePrompt(action:.setup(enableLock:true)) }
                else if !enabled { model.codePrompt = AppCodePrompt(action:.lock(false)) }
                else { apply(enabled:enabled,biometric:model.appEntryBiometricEnabled) }
            }))
            Text(ProductText.string("ios_entry_lock_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            Toggle(ProductText.string("auth_use_biometric"),isOn:Binding(get:{ model.appEntryBiometricEnabled },set:{ enabled in
                if enabled { model.codePrompt = AppCodePrompt(action:.biometric(true)) }
                else { apply(enabled:model.appLockEnabled,biometric:false) }
            })).disabled(!model.hasActionCode || (!ActionBiometrics.available && !model.appEntryBiometricEnabled))
            Text(ProductText.string(ActionBiometrics.available || model.appEntryBiometricEnabled ? "ios_entry_bio_hint" : "ios_entry_bio_unavailable")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            }
        }.disabled(working || !model.canManageGuestAccess)
    }
    private func apply(enabled: Bool,biometric: Bool) {
        guard !working else { return }; working = true
        Task {
            defer { working = false }
            do {
                if !(try await model.configureEntryLock(enabled:enabled,biometric:biometric,code:"")) { model.errorMessage = ProductText.string("code_err_wrong") }
            } catch { model.errorMessage = ProductText.string("ios_code_save_failed") }
        }
    }
}

struct AppCodeDialog: View {
    @EnvironmentObject private var model: AppModel
    let request: AppCodePrompt
    @State private var current = ""
    @State private var replacement = ""
    @State private var repeated = ""
    @State private var passedCurrent = false
    @State private var working = false
    @State private var error: String?
    private var settingUp: Bool {
        switch request.action { case .setup: return true; case .change: return passedCurrent; default: return false }
    }
    private var ready: Bool {
        settingUp ? (4...8).contains(replacement.count) && replacement == repeated : (4...8).contains(current.count)
    }
    var body: some View {
        AppDialogSurface {
            VStack(alignment:.leading,spacing:16) {
                Text(ProductText.string(settingUp ? "code_title" : "code_current")).font(.title3.bold())
                if settingUp {
                    Text(ProductText.string("code_setup_hint")).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    field(ProductText.string("code_field"),text:$replacement)
                    field(ProductText.string("code_field_repeat"),text:$repeated)
                } else { field(ProductText.string("code_current"),text:$current) }
                if let error { Text(error).font(.footnote).foregroundStyle(AppPalette.destructive) }
                HStack(spacing:12) {
                    Button(ProductText.string("btn_cancel")) { model.codePrompt = nil }.buttonStyle(SecondaryActionStyle())
                    Button { submit() } label: { ActionButtonLabel(title:ProductText.string(settingUp ? "btn_save" : "btn_ok"),busy:working) }.buttonStyle(PrimaryActionStyle()).disabled(!ready)
                }
            }.disabled(working || !model.canManageGuestAccess)
        }
    }
    private func field(_ title: String,text: Binding<String>) -> some View {
        AppField(title) {
            SecureField(title,text:text).keyboardType(.numberPad).textContentType(.password)
                .padding(14).background(Color(uiColor:.tertiarySystemFill),in:RoundedRectangle(cornerRadius:12))
                .onChange(of:text.wrappedValue) { text.wrappedValue = String($0.filter { $0.isASCII && $0.isNumber }.prefix(8)) }
        }
    }
    private func submit() {
        guard !working, ready, model.canManageGuestAccess else { return }; working = true; error = nil
        Task {
            defer { working = false }
            do {
                switch request.action {
                case .change where !passedCurrent:
                    guard try await model.verifySettingsCode(current) else { error = ProductText.string("code_err_wrong"); current = ""; return }
                    passedCurrent = true; return
                case .change:
                    guard try await model.changeActionCode(current:current,replacement:replacement) else { error = ProductText.string("code_err_wrong"); return }
                case .setup(let enableLock):
                    try await model.setActionCode(replacement)
                    if enableLock {
                        guard try await model.configureEntryLock(enabled:true,biometric:model.appEntryBiometricEnabled,code:"") else { throw KeychainStore.Failure(status:-1) }
                    }
                case .lock(let enabled):
                    guard try await model.configureEntryLock(enabled:enabled,biometric:model.appEntryBiometricEnabled,code:current) else { error = ProductText.string("code_err_wrong"); current = ""; return }
                case .biometric(let enabled):
                    guard try await model.configureEntryLock(enabled:model.appLockEnabled,biometric:enabled,code:current) else { error = ProductText.string("code_err_wrong"); current = ""; return }
                }
                current = ""; replacement = ""; repeated = ""; model.codePrompt = nil
            } catch {
                // A successful first save may precede a failed lock-setting
                // save. Keep that real code and let the controls reflect it.
                self.error = ProductText.string("ios_code_save_failed")
                if case .setup = request.action, model.hasActionCode { model.codePrompt = nil; model.errorMessage = self.error }
            }
        }
    }
}
