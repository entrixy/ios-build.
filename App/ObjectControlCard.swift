import SwiftUI
import EntrixyCore

/// ActionCard.kt: independent trailing camera button, stream below the same
/// action row, all inside one card. No nested buttons or separate camera page.
struct ObjectControlCard<MainLabel: View>: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var automation: AutomationCoordinator
    let entry: CatalogObject
    let accessibilityText: String
    let action: () -> Bool
    let mainLabel: () -> MainLabel
    init(automation: AutomationCoordinator, entry: CatalogObject, accessibilityText: String,
         action: @escaping () -> Bool, @ViewBuilder mainLabel: @escaping () -> MainLabel) {
        _automation = ObservedObject(wrappedValue:automation)
        self.entry = entry; self.accessibilityText = accessibilityText; self.action = action; self.mainLabel = mainLabel
    }
    @State private var cameraOpen = false
    private var camera: ObjectCameraContext? { app.cameraContext(entry.target) }
    private var nearby: Bool {
        guard let context = try? app.automationContext(.object(entry.target)), context.template.geoEnabled,
              let distance = automation.readiness[entry.target]?.distanceM else { return false }
        return distance <= Double(context.template.radiusM ?? 30)
    }
    private var pendingCall: Bool {
        guard case let .owned(owner,object) = entry else { return false }
        return app.ownerControl.phoneRequests.contains { $0.server == owner.server && $0.objectID == object.id }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Button {
                    AppSoundCenter.shared.play(.tap)
                    let accepted = action()
                    if !accepted { AppSoundCenter.shared.play(.error) }
                    if accepted, camera?.configuration.showWhen == "call" { cameraOpen = true }
                } label: { mainLabel().frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }
                    .buttonStyle(CardActionStyle()).accessibilityLabel(accessibilityText)
                    .accessibilityHint(ProductText.string("ios_object_action_accessibility"))
                if camera != nil {
                    Button { withAnimation(.easeInOut(duration:0.18)) { cameraOpen.toggle() } } label: {
                        Image(systemName:"video").font(.system(size:24)).foregroundStyle(Brand.ink)
                            .frame(width:44,height:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(ProductText.string("stream_enable"))
                        .accessibilityValue(cameraOpen ? ProductText.string("btn_close") : ProductText.string("btn_open"))
                }
            }
            if cameraOpen, let camera { ObjectCameraStream(context:camera) }
        }
        .padding(16).background(.background,in:RoundedRectangle(cornerRadius:22))
        .onAppear { updateVisibility() }
        .onChange(of:camera) { value in if value == nil { cameraOpen = false } else { updateVisibility() } }
        .onChange(of:nearby) { _ in updateVisibility() }
        .onChange(of:pendingCall) { _ in updateVisibility() }
        .onChange(of:app.cameraActivity[entry.target]) { _ in
            if camera?.configuration.showWhen == "call" { cameraOpen = true }
        }
    }
    private func updateVisibility() {
        guard let camera else { return }
        if camera.configuration.showWhen == "always" || (camera.configuration.showWhen == "nearby" && nearby) || (camera.configuration.showWhen == "call" && pendingCall) { cameraOpen = true }
    }
}
