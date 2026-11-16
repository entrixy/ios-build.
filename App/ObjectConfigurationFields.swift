import SwiftUI
import ContactsUI
import EntrixyCore

struct WebhookConfigurationFields: View {
    @Binding var url: String
    @Binding var secret: String
    @Binding var mode: String
    @Binding var toggles: Bool
    @State private var revealing = false
    var body: some View {
        AppField(ProductText.string("add_object_webhook_url")) {
            TextField(ProductText.string("add_object_webhook_url_placeholder"), text: $url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        AppField(ProductText.string("add_object_webhook_secret")) {
            HStack {
                Group {
                    if revealing { TextField("",text:$secret) } else { SecureField("",text:$secret) }
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { revealing.toggle() } label: { Image(systemName: revealing ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel("Показать секрет")
                Button { UIPasteboard.general.string = secret } label: { Image(systemName:"doc.on.doc") }.buttonStyle(.borderless).accessibilityLabel(ProductText.string("btn_copy"))
                Button { secret = GuestCrypto.base64URL(GuestCrypto.randomBytes(count:24)) } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Новый секрет")
            }
            Text(ProductText.string("add_object_webhook_secret_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
        }
        Picker(ProductText.string("guest_tpl_wifi_mode"),selection:$mode) {
            Text(ProductText.string("add_object_webhook_mode_phone")).tag("phone")
            Text(ProductText.string("add_object_webhook_mode_server")).tag("server")
        }.pickerStyle(.inline)
        Picker(ProductText.string("webhook_kind_title"),selection:$toggles) {
            Text(ProductText.string("webhook_kind_pulse")).tag(false)
            Text(ProductText.string("webhook_kind_toggle")).tag(true)
        }.pickerStyle(.inline)
    }
}

struct ObjectCameraFields: View {
    @Binding var camera: ObjectCameraConfiguration
    private var video: Bool {
        let path = camera.url.lowercased().split(separator:"?").first.map(String.init) ?? ""
        return path.hasPrefix("rtsp://") || path.hasPrefix("rtmp://") || [".m3u8",".mpd",".mp4",".webm",".mkv"].contains { path.hasSuffix($0) }
    }
    var body: some View {
        Toggle(ProductText.string("snap_title"),isOn:$camera.enabled)
        if camera.enabled {
            AppField(ProductText.string("snap_url_label")) {
                TextField("https://cam.example.com/snap.jpg",text:$camera.url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Text(ProductText.string(camera.url.isEmpty ? "snap_type_unknown" : video ? "snap_type_video" : "snap_type_jpeg"))
                .font(.footnote).foregroundStyle(Brand.secondaryInk)
            Picker(ProductText.string("automation_rule_auth"),selection:$camera.authType) {
                ForEach(["none","basic","bearer","header"],id:\.self) { value in Text(ProductText.string("snap_auth_"+value)).tag(value) }
            }.pickerStyle(.segmented)
            if camera.authType == "header" {
                AppField(ProductText.string("snap_auth_header_name")) {
                    TextField("X-Api-Key",text:$camera.authHeader).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            if camera.authType != "none" {
                AppField(ProductText.string("snap_auth_"+camera.authType+"_value")) {
                    SecureField("",text:$camera.authValue).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            if !video {
                Text(ProductText.string("snap_interval",camera.intervalSec))
                Slider(value:Binding(get:{ Double(camera.intervalSec) },set:{ camera.intervalSec=Int($0) }),in:0...30,step:1)
            }
            Picker(ProductText.string("snap_show_when_title"),selection:$camera.showWhen) {
                ForEach(["always","call","nearby"],id:\.self) { value in Text(ProductText.string("snap_when_"+value)).tag(value) }
            }.pickerStyle(.inline)
        }
    }
}

struct DeviceCredentialsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let credentials: DeviceConfigurationCredentials
    let server: String
    private var code: String { (try? credentials.code(server:server)) ?? "" }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    Text(ProductText.string("device_qr_body"))
                    AppField(ProductText.string("device_qr_code")) {
                        Text(code.replacingOccurrences(of:"ENTX-DEV:",with:"")).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                    }
                    Button { UIPasteboard.general.string=code } label: { Label(ProductText.string("btn_copy"),systemImage:"doc.on.doc") }
                        .buttonStyle(SecondaryActionStyle())
                    Text(ProductText.string("device_qr_server_note",server)).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    ShareLink(item:ProductText.string("device_code_share_fmt",code.replacingOccurrences(of:"ENTX-DEV:",with:""),server)) {
                        Label(ProductText.string("btn_share"),systemImage:"square.and.arrow.up")
                    }.buttonStyle(PrimaryActionStyle())
                }.padding(DesignMetrics.pageInset)
            }.background(Color(uiColor:.systemGroupedBackground))
                .navigationTitle(ProductText.string("device_qr_title")).navigationBarTitleDisplayMode(.inline)
                .sheetDismissFooter(ProductText.string("btn_done")) { dismiss() }
        }
    }
}

struct ObjectPhoneContactPicker: UIViewControllerRepresentable {
    let selected: (String,String) -> Void
    var cancelled: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(selected, cancelled: cancelled) }
    func makeUIViewController(context:Context) -> CNContactPickerViewController {
        let picker=CNContactPickerViewController();picker.delegate=context.coordinator
        picker.displayedPropertyKeys=[CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact=NSPredicate(format:"phoneNumbers.@count > 0")
        picker.predicateForSelectionOfContact=NSPredicate(value: false)
        picker.predicateForSelectionOfProperty=NSPredicate(format:"key == %@", CNContactPhoneNumbersKey)
        return picker
    }
    func updateUIViewController(_ uiViewController:CNContactPickerViewController,context:Context) {}
    final class Coordinator:NSObject,CNContactPickerDelegate {
        let selected:(String,String)->Void
        let cancelled: () -> Void
        init(_ selected:@escaping(String,String)->Void, cancelled:@escaping()->Void) { self.selected=selected; self.cancelled=cancelled }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { cancelled() }
        func contactPicker(_ picker:CNContactPickerViewController,didSelect contactProperty:CNContactProperty) {
            guard let number=contactProperty.value as? CNPhoneNumber else { return }
            selected(number.stringValue,CNContactFormatter.string(from:contactProperty.contact,style:.fullName) ?? "")
        }

    }
}
