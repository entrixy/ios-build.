import SwiftUI

struct AppEntryLockScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var code = ""
    @State private var working = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
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
                Spacer()
            }.padding(DesignMetrics.pageInset)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Вход в Entrixy").navigationBarTitleDisplayMode(.inline)
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
    @State private var code = ""
    @State private var newCode = ""
    @State private var repeated = ""
    @State private var enabled = false
    @State private var biometric = false
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Form {
            if model.hasActionCode {
                Section {
                    AppField("Текущий код Entrixy") { SecureField("Текущий код", text: $code).keyboardType(.numberPad) }
                    Toggle("Запрашивать код при входе", isOn: $enabled)
                    Toggle("Биометрия для входа", isOn: $biometric)
                        .disabled(!ActionBiometrics.available && !model.appEntryBiometricEnabled)
                    Button("Сохранить настройки входа") { save() }.buttonStyle(PrimaryActionStyle())
                } header: { Text("Вход в приложение") } footer: {
                    Text("Код запрашивается при запуске и после минуты в фоне. Для отключения входа и включения биометрии нужен текущий код. Права и условия объектов настраиваются отдельно.")
                }
            }
            Section {
                AppField("Новый код Entrixy") { SecureField("От 4 до 8 цифр", text: $newCode).keyboardType(.numberPad) }
                AppField("Повторите новый код") { SecureField("Повторите код", text: $repeated).keyboardType(.numberPad) }
                Button(model.hasActionCode ? "Изменить код" : "Задать код") { changeCode() }
                    .buttonStyle(SecondaryActionStyle()).disabled(newCode != repeated || !(4...8).contains(newCode.count))
            } header: { Text(model.hasActionCode ? "Изменение кода" : "Код Entrixy") } footer: {
                Text("Этот же код подтверждает защищённые действия с объектами. Он не копируется с другого телефона.")
            }
            if let message { Section { Text(message).foregroundStyle(Brand.secondaryInk) } }
        }
        .disabled(working)
        .navigationTitle("Код и вход").navigationBarTitleDisplayMode(.inline)
        .task { enabled = model.appLockEnabled; biometric = model.appEntryBiometricEnabled }
    }
    private func save() {
        guard !working else { return }; working = true; message = nil
        Task {
            defer { working = false; code = "" }
            do {
                message = try await model.configureEntryLock(enabled: enabled, biometric: biometric, code: code)
                    ? "Настройки входа сохранены." : "Код не принят. Настройки не изменялись."
            } catch { message = "Не удалось сохранить настройки входа. Прежняя защита сохранена." }
            enabled = model.appLockEnabled; biometric = model.appEntryBiometricEnabled
        }
    }
    private func changeCode() {
        guard !working else { return }; working = true; message = nil
        Task {
            defer { working = false; code = ""; newCode = ""; repeated = "" }
            do {
                if model.hasActionCode {
                    message = try await model.changeActionCode(current: code, replacement: newCode)
                        ? "Код изменён." : "Текущий код не принят. Код не изменялся."
                } else { try await model.setActionCode(newCode); message = "Код задан. Вход по коду можно включить выше." }
            } catch { message = "Не удалось сохранить код. Прежние данные сохранены." }
        }
    }
}
