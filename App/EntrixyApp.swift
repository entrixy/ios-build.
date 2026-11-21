import SwiftUI
import Combine
import EntrixyCore

@main
struct EntrixyApp: App {
    @UIApplicationDelegateAdaptor(EntrixyLifecycleDelegate.self) private var lifecycle
    @AppStorage("entrixy.appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG && targetEnvironment(simulator)
            if let route = StageTwoCapture.current {
                StageTwoRoot(route: route)
            } else if let page = NativeDesignCatalog.requestedPage {
                NativeDesignCatalog(page: page)
            } else if let scenario = ActionCaptureScenario.current {
                ActionCaptureRoot(scenario: scenario)
            } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
                // Hosted unit tests compose their own isolated model/policy.
                Color.clear
            } else {
                LiveAppRoot()
            }
            #else
            LiveAppRoot()
            #endif
            }
            .toggleStyle(SelectedSwitchStyle())
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

private struct LiveAppRoot: View {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var pendingURL: URL?
    @State private var widgetPublisher = WidgetPresentationPublisher()
    init() {
        // Keep router construction inside StateObject's deferred initializer.
        // Rebuilding this View must not replace the retained model's global gate.
        _model = StateObject(wrappedValue:LiveAppRuntime.model())
    }
    var body: some View {
        Group {
            if model.appLocked || model.entryRequiresUnlock() { AppEntryLockScreen() }
            else { RootView(initialTab: PreviewRouting.tab, showAddKey: PreviewRouting.addKey, pendingURL: $pendingURL) }
        }
        .environmentObject(model)
        .background(AppPrivacyShield(enabled: model.appLockEnabled, covered: phase != .active).frame(width: 0, height: 0))
        .task {
            AppNotificationRouting.shared.install()
            model.checkEntryLock(); WidgetActionInbox.shared.bind(model)
            try? widgetPublisher.publish(model)
            if phase == .background { model.enterBackground() }
            else {
                _ = await model.prepareServerRouting(); await model.resume()
                WidgetActionInbox.shared.setReady(true); model.diagnostics.activate(); model.promotions.activate(); model.remoteNotifications.activate()
            }
        }
        .onReceive(model.objectWillChange.debounce(for:.milliseconds(250),scheduler:RunLoop.main)) { _ in try? widgetPublisher.publish(model); model.remoteNotifications.schedule() }
        .onReceive(model.ownerControl.objectWillChange.debounce(for:.milliseconds(250),scheduler:RunLoop.main)) { _ in try? widgetPublisher.publish(model) }
        .onOpenURL { pendingURL = $0 }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { pendingURL = url }
        }
        .onChange(of: phase) { value in
            if value == .active {
                model.checkEntryLock()
                Task {
                    _ = await model.prepareServerRouting(); await model.resume()
                    WidgetActionInbox.shared.setReady(true); model.diagnostics.activate(); model.promotions.activate(); model.remoteNotifications.activate()
                }
            } else if value == .background {
                WidgetActionInbox.shared.cancel(); model.entryDidBackground(); model.enterBackground()
                try? widgetPublisher.publish(model,forceOffline:true)
            }
        }
        .onChange(of:model.appLocked) { locked in
            if !locked && phase == .active {
                Task { await model.resume(); WidgetActionInbox.shared.setReady(true); model.diagnostics.activate(); model.promotions.activate(); model.remoteNotifications.activate() }
            }
        }
    }
}

struct RootView: View {
    private struct DeviceClaimPrompt: Identifiable { let id = UUID(); let claim: DeviceClaimLink }
    private struct DeviceCredentialsPrompt: Identifiable { let id = UUID(); let server: String; let credentials: DeviceConfigurationCredentials }
    @EnvironmentObject private var model: AppModel
    @AppStorage("entrixy.language") private var language = ""
    @State private var selectedTab: AppTab
    @State private var userPickedTab = false
    @State private var adding = false
    @State private var input = ""
    @State private var companyObjectFlow: KnownCompany?
    @State private var deviceClaimFlow: DeviceClaimPrompt?
    @State private var claimCreatedDevice: ObjectReference?
    @State private var claimDeviceCredentials: DeviceCredentialsPrompt?
    private let showAddKeyOnLaunch: Bool
    @Binding private var pendingURL: URL?

    init(initialTab: AppTab = .control, showAddKey: Bool = false, pendingURL: Binding<URL?> = .constant(nil)) {
        _selectedTab = State(initialValue: initialTab)
        showAddKeyOnLaunch = showAddKey
        _pendingURL = pendingURL
    }

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
            NavigationStack {
                Group {
                    switch model.navigationState.resolve(selectedTab) {
                    case .control: ControlScreen { input = ""; adding = true }.modifier(BrandNavigationHeader())
                    case .settings: SettingsScreen().modifier(BrandNavigationHeader())
                    case .guests: OwnerGuestsScreen().modifier(BrandNavigationHeader())
                    case .journal: JournalScreen().modifier(BrandNavigationHeader())
                    }
                }
            }.id(selectedTab.rawValue + ":" + language)
            // Reserve a real sibling layout region. UIKit lists inside a
            // NavigationStack can cover an outer safeAreaInset's hit targets.
            AppBottomNavigation(selection: $selectedTab, tabs: model.navigationState.tabs) { userPickedTab = true }
                .allowsHitTesting(model.localTaskDialogs.isEmpty).accessibilityHidden(!model.localTaskDialogs.isEmpty)
                .overlay {
                    if !model.localTaskDialogs.isEmpty {
                        Color.black.opacity(DesignMetrics.dialogDimOpacity).ignoresSafeArea(edges:.bottom)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
        .accessibilityHidden(model.hasInlineRootDialog)
        .allowsHitTesting(!model.hasRootDialog)
        .overlay { BackupFlowHost(flow:model.backupPresentation) }
        // Keep the modal a sibling of the hidden navigation tree. An overlay
        // on an accessibility-hidden ancestor can inherit that ancestor's
        // accessibility state while UIKit is resolving the settings List.
        Group {
            if let prompt = model.actionPrompt { ActionConfirmation(request:prompt).id(prompt.id) }
            else if let accepted = model.keyAcceptance { KeyAcceptanceDialog(sensors:model.automationSensors,presentation:accepted).id(accepted.id) }
            else if let prompt = model.serverPrompt { ServerSettingsDialog(prompt:prompt).id(prompt.id) }
            else if let network = model.networkPrivacyPrompt { NetworkPrivacyDialog(network:network) }
            else if let prompt = model.codePrompt { AppCodeDialog(request:prompt).id(prompt.id) }
            else if let target = model.objectRemovalTarget { ObjectRemovalConfirmation(target: target) }
            else if let target = model.objectAvatarTarget { ObjectAvatarPicker(target: target) }
            else if let target = model.bleInformationTarget { BLEInformationDialog(target:target) }
            else if let target = model.guestRemovalTarget { GuestRemovalDialog(target:target) }
            else if let id = model.companyRequestID, let company = model.companies.first(where:{ $0.id == id }) {
                CompanyRequestDialog(company:company) { granted,hasObjects in
                    model.companyRequestID = nil
                    if granted || hasObjects {
                        model.companyGrantRequest = granted ? "" : company.id
                        userPickedTab = true; selectedTab = .guests
                    } else { companyObjectFlow = company }
                }
            } else { OwnerPhoneRequestDialog(control: model.ownerControl) }
        }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .background(DiagnosticConsentPresenter(service:model.diagnostics).frame(width:0,height:0))
        .background(IncomingMessagePresenter(manager:model.messages).frame(width:0,height:0))
        .onChange(of: model.navigationState) { value in
            if !userPickedTab && value.hasActions && selectedTab == .settings { selectedTab = .control }
            else { selectedTab = value.resolve(selectedTab) }
        }
        .tint(Brand.primary)
        .environment(\.locale,Locale(identifier:ProductText.language))
        .task {
            selectedTab = model.navigationState.resolve(selectedTab)
            if let url = pendingURL { pendingURL = nil; receiveURL(url) }
            if showAddKeyOnLaunch {
                try? await Task.sleep(nanoseconds: 400_000_000)
                adding = true
            }
        }
        .onChange(of: pendingURL) { url in
            if let url { pendingURL = nil; receiveURL(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for:.entrixyWidgetAction)) { _ in
            selectedTab = model.navigationState.resolve(.control); userPickedTab = true
        }
        .onReceive(NotificationCenter.default.publisher(for:.entrixyAutomationFocus)) { _ in
            selectedTab = model.navigationState.resolve(.control); userPickedTab = true
        }
        .onChange(of:model.canManageGuestAccess) { if $0 { model.diagnostics.offerConsent() } }
        .onChange(of:language) { _ in model.promotions.languageChanged() }
        .sheet(isPresented: $adding) { KeyImportScreen(input: $input) }
        .sheet(item:$deviceClaimFlow,onDismiss:{
            defer { claimCreatedDevice = nil }
            if case let .owned(server,id) = claimCreatedDevice,
               let credentials = try? model.ownerDeviceCredentials(server:server,objectID:id) {
                claimDeviceCredentials = DeviceCredentialsPrompt(server:server,credentials:credentials)
            }
        }) { prompt in
            AddOwnerObjectScreen(server:prompt.claim.server,initialClaimCode:prompt.claim.code,completion:{ claimCreatedDevice = $0 })
        }
        .sheet(item:$claimDeviceCredentials) { prompt in DeviceCredentialsSheet(credentials:prompt.credentials,server:prompt.server) }
        .sheet(item:$companyObjectFlow) { company in
            if model.owners.contains(where:{ $0.server == company.server && $0.credentials != nil }) { AddOwnerObjectScreen(server:company.server) }
            else { AddOwnerServerScreen(initialServer:company.server) }
        }
        .appMessageDialog("Entrixy",message:model.errorMessage ?? "",actionTitle:"Понятно",isPresented:Binding(get: { model.errorMessage != nil && !adding }, set: { if !$0 && !adding { model.errorMessage = nil } }))
    }
    private func receiveURL(_ url: URL) {
        if url.isFileURL, ["eib","ekb"].contains(url.pathExtension.lowercased()) {
            selectedTab = .settings; userPickedTab = true; model.settingsRequest = .system
            if !model.backups.hasPendingRestore { Task { await model.backupPresentation.acceptFile(.success(url)) } }
            return
        }
        if DeviceClaimLink.recognizes(url) {
            do {
                let claim = try DeviceClaimLink.parse(url,selectedServer:model.selectedOwnerServer)
                selectedTab = .settings; userPickedTab = true; model.settingsRequest = .objects
                deviceClaimFlow = DeviceClaimPrompt(claim:claim)
            } catch { model.errorMessage = "В ссылке нет корректного кода привязки устройства." }
            return
        }
        if let company = try? CompanyInvite.parse(url.absoluteString) {
            Task { await model.receiveCompanyInvite(company) }; return
        }
        do { input = try AccessLink.incomingText(url.absoluteString); adding = true }
        catch { model.errorMessage = "В этой ссылке не найден поддерживаемый ключ Entrixy." }
    }
}

enum Brand {
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : UIColor(red: 27.0/255, green: 29.0/255, blue: 59.0/255, alpha: 1)
    })
    static let secondaryInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.75, alpha: 1) : UIColor(red: 84.0/255, green: 90.0/255, blue: 107.0/255, alpha: 1)
    })
    static let primary = ink

}

struct BrandNavigationHeader: ViewModifier {
    @State private var showingHelp = false
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(.large).toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) { AppLogoMenu { showingHelp = true } }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigationBarLeading) { AppLogoMenu { showingHelp = true } }
            }
        }.navigationDestination(isPresented:$showingHelp) { HelpScreen() }
    }
}

/// Exact polygon geometry and independent LED timing from logo-animated-icon.svg.
/// The mark owns its circle and never shares a glass capsule with adjacent actions.
struct BrandLogo: View {
    private let fixedFaces: [[CGPoint]] = [
        [.init(x: 0, y: 40.7), .init(x: 0, y: 52.4), .init(x: 10.8, y: 56.6), .init(x: 10.8, y: 45)],
        [.init(x: 0, y: 17.5), .init(x: 0, y: 29.1), .init(x: 10.8, y: 33.3), .init(x: 10.8, y: 21.7)]
    ]
    private let lights: [[CGPoint]] = [
        [.init(x: 36.7, y: 11.6), .init(x: 10.8, y: 21.7), .init(x: 10.8, y: 10.1), .init(x: 36.7, y: 0)],
        [.init(x: 36.7, y: 34.9), .init(x: 10.8, y: 45), .init(x: 10.8, y: 33.3), .init(x: 36.7, y: 23.3)],
        [.init(x: 36.7, y: 58.2), .init(x: 10.8, y: 68.2), .init(x: 10.8, y: 56.6), .init(x: 36.7, y: 46.5)]
    ]
    var body: some View {
        ZStack {
            ForEach(fixedFaces.indices, id: \.self) { index in
                BrandFacet(vertices: fixedFaces[index]).fill(Brand.ink)
            }
            ForEach(lights.indices, id: \.self) { index in
                BrandLED(vertices: lights[index], initialColor: index)
            }
        }
        .frame(width: 15.07, height: 28)
        .frame(width: 44, height: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Entrixy")
    }
}

private struct BrandFacet: Shape {
    let vertices: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in vertices.enumerated() {
            let mapped = CGPoint(x: rect.minX + point.x / 36.7 * rect.width,
                                 y: rect.minY + point.y / 68.2 * rect.height)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        path.closeSubpath()
        return path
    }
}

private struct BrandLED: View {
    let vertices: [CGPoint]
    let initialColor: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var colorIndex = 2
    private var animate: Bool { !reduceMotion && phase == .active }
    private var colors: [Color] {
        [Color(red: 226.0/255, green: 116.0/255, blue: 116.0/255),
         Color(red: 149.0/255, green: 193.0/255, blue: 31.0/255), Brand.ink]
    }
    var body: some View {
        BrandFacet(vertices: vertices).fill(colors[colorIndex])
            .task(id: animate) {
                guard animate else { colorIndex = 2; return }
                colorIndex = initialColor
                do {
                    try await Task.sleep(nanoseconds: UInt64(Double.random(in: 0...400) * 1_000_000))
                    while !Task.isCancelled {
                        let next = (0..<3).filter { $0 != colorIndex }.randomElement()!
                        withAnimation(.easeInOut(duration: 0.25)) { colorIndex = next }
                        let delay = 80 + pow(Double.random(in: 0...1), 2.2) * 1600
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
                    }
                } catch { /* View disappeared or motion/foreground preference changed. */ }
            }
    }
}

struct EmptyScreen: View {
    let image: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 16) {
            Image(image).resizable().renderingMode(.template).scaledToFit()
                .frame(width: 44, height: 44).foregroundStyle(Brand.primary)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
