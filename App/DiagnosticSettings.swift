import SwiftUI

struct DiagnosticSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: AppDiagnostics
    var body: some View {
        Section {
            Toggle(isOn:Binding(get:{ service.enabled },set:{ service.setConsent($0) })) {
                VStack(alignment:.leading,spacing:5) {
                    Text(ProductText.string("crash_reports_title"))
                    Text(ProductText.string("crash_reports_body")).font(.footnote).foregroundStyle(Brand.secondaryInk)
                }
            }.accessibilityIdentifier("diagnostics-consent-switch").disabled(!service.ready || !model.canManageGuestAccess)
            if service.message == "ios_diag_storage_failed" { Text(ProductText.string("ios_diag_storage_failed")).font(.footnote).foregroundStyle(AppPalette.destructive) }
        }
    }
}

struct DiagnosticConsentDialog: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: AppDiagnostics
    var body: some View {
        AppDialogSurface {
            VStack(alignment:.leading,spacing:18) {
                Text(ProductText.string("crash_consent_title")).font(.title3.bold())
                Text(ProductText.string("crash_consent_text"))
                if let message = service.message { Text(ProductText.string(message)).font(.footnote).foregroundStyle(AppPalette.destructive) }

            }.disabled(!service.ready || !model.canManageGuestAccess)
        } footer: {
                HStack(spacing:12) {
                    Button(ProductText.string("crash_consent_later")) { service.setConsent(false) }
                        .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("diagnostic-consent-later")
                    Button(ProductText.string("crash_consent_allow")) { service.setConsent(true) }
                        .buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("diagnostic-consent-allow")
                }.disabled(!service.ready || !model.canManageGuestAccess)
        }
    }
}

/// Same hidden seven-tap entry and manual send/off actions as Android.
struct DeveloperSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: AppDiagnostics
    @AppStorage("entrixy.developerMode") private var developerMode = false
    var body: some View {
        if developerMode {
            Section {
                Text(ProductText.string("ios_diag_manual_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            } header: { Text(ProductText.string("ios_developer_title")) }
            Section {
                Button { Task { await service.sendManual() } } label: { ActionButtonLabel(title:ProductText.string("log_send"),busy:service.sending) }
                    .buttonStyle(PrimaryActionStyle()).actionListRow().accessibilityIdentifier("diagnostics-send")
                    .disabled(service.sending || !service.ready || !model.canManageGuestAccess)
            }
            if let message = service.message,message != "ios_diag_storage_failed" {
                Section { Text(ProductText.string(message)).font(.footnote).foregroundStyle(message == "ios_diag_sent" ? Brand.secondaryInk : AppPalette.destructive) }
            }
            Section {
                Button(ProductText.string("ios_developer_off")) { developerMode = false }
                    .buttonStyle(SecondaryActionStyle()).actionListRow().accessibilityIdentifier("developer-disable")
            }
        }
    }
}
