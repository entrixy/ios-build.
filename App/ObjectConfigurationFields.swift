import SwiftUI
import ContactsUI
import EntrixyCore

struct WebhookConfigurationFields: View {
    @Binding var url: String
    @Binding var secret: String
    @Binding var mode: String
    @Binding var toggles: Bool
    let requestServerMode: () -> Void
    var body: some View {
        AppField(ProductText.string("add_object_webhook_url")) {
            TextField(ProductText.string("add_object_webhook_url_placeholder"), text: $url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        AppField(ProductText.string("add_object_webhook_secret")) {
            HStack {
                TextField("", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { UIPasteboard.general.string = secret } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(SquareIconActionStyle()).accessibilityLabel(ProductText.string("btn_copy")).disabled(secret.isEmpty)
            }
            Text(ProductText.string("add_object_webhook_secret_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
        }
        VStack(alignment: .leading, spacing: 4) {
            ObjectRadioChoice(title: ProductText.string("add_object_webhook_mode_phone"), selected: mode == "phone") { mode = "phone" }
            ObjectRadioChoice(title: ProductText.string("add_object_webhook_mode_server"), selected: mode == "server") {
                if mode != "server" { requestServerMode() }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(ProductText.string("webhook_kind_title")).font(.subheadline.weight(.semibold))
            ObjectRadioChoice(title: ProductText.string("webhook_kind_pulse"), selected: !toggles) { toggles = false }
            ObjectRadioChoice(title: ProductText.string("webhook_kind_toggle"), selected: toggles) { toggles = true }
        }
    }
}

struct WebhookServerModeConfirmation: View {
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        AppDialogSurface {
            VStack(alignment: .leading, spacing: 18) {
                Text(ProductText.string("webhook_server_mode_title")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text(ProductText.string("webhook_server_mode_warning"))

            }
        } footer: {
                HStack(spacing: 12) {
                    Button(ProductText.string("btn_cancel"), action: cancel).buttonStyle(SecondaryActionStyle())
                    Button(ProductText.string("btn_ok"), action: confirm).buttonStyle(PrimaryActionStyle())
                }
        }
    }
}

struct ObjectRadioChoice: View {
    let title: String
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AppPalette.selected : Brand.secondaryInk)
                Text(title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            }.foregroundStyle(Brand.ink).frame(minHeight: DesignMetrics.secondaryHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ObjectCameraFields: View {
    @Binding var camera: ObjectCameraConfiguration
    private var video: Bool {
        let path = camera.url.lowercased().split(separator:"?").first.map(String.init) ?? ""
        return path.hasPrefix("rtsp://") || path.hasPrefix("rtmp://") || [".m3u8",".mpd",".mp4",".webm",".mkv"].contains { path.hasSuffix($0) }
    }
    var body: some View {
        Toggle(isOn: $camera.enabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ProductText.string("snap_title"))
                Text(ProductText.string("snap_hint")).font(.footnote).foregroundStyle(Brand.secondaryInk)
            }
        }.tint(AppPalette.selected).accessibilityIdentifier("object-camera-enabled")
        if camera.enabled {
            AppField(ProductText.string("snap_url_label")) {
                TextField("https://cam.example.com/snap.jpg",text:$camera.url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("object-camera-url")
            }
            Text(ProductText.string(camera.url.isEmpty ? "snap_type_unknown" : video ? "snap_type_video" : "snap_type_jpeg"))
                .font(.footnote).foregroundStyle(Brand.secondaryInk)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(["none", "basic", "bearer", "header"], id: \.self) { value in
                    Button { camera.authType = value } label: { Text(ProductText.string("snap_auth_" + value)).font(.subheadline) }
                        .buttonStyle(SelectedOptionStyle(selected:camera.authType == value))
                        .accessibilityAddTraits(camera.authType == value ? .isSelected : [])
                }
            }
            if camera.authType == "header" {
                AppField(ProductText.string("snap_auth_header_name")) {
                    TextField("X-Api-Key",text:$camera.authHeader).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            if camera.authType != "none" {
                AppField(ProductText.string("snap_auth_"+camera.authType+"_value")) {
                    TextField("",text:$camera.authValue).textInputAutocapitalization(.never).autocorrectionDisabled().textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            if !video {
                Text(ProductText.string("snap_interval",camera.intervalSec))
                Slider(value:Binding(get:{ Double(camera.intervalSec) },set:{ camera.intervalSec=Int($0) }),in:0...30,step:1).tint(AppPalette.selected)
            }
            Text(ProductText.string("snap_show_when_title")).font(.subheadline)
            ForEach(["always","call","nearby"],id:\.self) { value in
                ObjectRadioChoice(title:ProductText.string("snap_when_"+value),selected:camera.showWhen == value) { camera.showWhen=value }
                    .accessibilityIdentifier("camera-show-"+value)
            }
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
                .taskSheetTitle(ProductText.string("device_qr_title"))
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
