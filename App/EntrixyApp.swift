import SwiftUI
import EntrixyCore

@main
struct EntrixyApp: App {
    @AppStorage("entrixy.appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG && targetEnvironment(simulator)
            if let page = NativeDesignCatalog.requestedPage {
                NativeDesignCatalog(page: page)
            } else if let scenario = ActionCaptureScenario.current {
                ActionCaptureRoot(scenario: scenario)
            } else {
                LiveAppRoot()
            }
            #else
            LiveAppRoot()
            #endif
            }
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

private struct LiveAppRoot: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @State private var pendingURL: URL?
    var body: some View {
        Group {
            if model.appLocked || model.entryRequiresUnlock() { AppEntryLockScreen() }
            else { RootView(initialTab: PreviewRouting.tab, showAddKey: PreviewRouting.addKey, pendingURL: $pendingURL) }
        }
        .environmentObject(model)
        .background(AppPrivacyShield(enabled: model.appLockEnabled, covered: phase != .active).frame(width: 0, height: 0))
        .task { model.checkEntryLock(); await model.resume() }
        .onOpenURL { pendingURL = $0 }
        .onChange(of: phase) { value in
            if value == .active { model.checkEntryLock(); Task { await model.resume() } }
            else if value == .background { model.entryDidBackground(); model.suspend() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: AppTab
    @State private var adding = false
    @State private var input = ""
    private let showAddKeyOnLaunch: Bool
    @Binding private var pendingURL: URL?

    init(initialTab: AppTab = .control, showAddKey: Bool = false, pendingURL: Binding<URL?> = .constant(nil)) {
        _selectedTab = State(initialValue: initialTab)
        showAddKeyOnLaunch = showAddKey
        _pendingURL = pendingURL
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ControlScreen { input = ""; adding = true }.modifier(BrandNavigationHeader()) }
                .tabItem { Label("Управление", image: "tab-control") }.tag(AppTab.control)
            NavigationStack { SettingsScreen().modifier(BrandNavigationHeader()) }
                .tabItem { Label("Настройки", image: "tab-settings") }.tag(AppTab.settings)
            NavigationStack { OwnerGuestsScreen().modifier(BrandNavigationHeader()) }.tabItem { Label("Гости", image: "tab-guests") }.tag(AppTab.guests)
            NavigationStack { JournalScreen().modifier(BrandNavigationHeader()) }
                .tabItem { Label("Журнал", image: "tab-journal") }.tag(AppTab.journal)
        }
        .tint(Brand.primary)
        .task {
            if let url = pendingURL { pendingURL = nil; receiveURL(url) }
            if showAddKeyOnLaunch {
                try? await Task.sleep(nanoseconds: 400_000_000)
                adding = true
            }
        }
        .onChange(of: pendingURL) { url in
            if let url { pendingURL = nil; receiveURL(url) }
        }
        .sheet(isPresented: $adding) { KeyImportScreen(input: $input) }
        .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil && !adding }, set: { if !$0 && !adding { model.errorMessage = nil } })) {
            Button("Понятно") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private func receiveURL(_ url: URL) {
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
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(.large).toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) { BrandLogo() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigationBarLeading) { BrandLogo() }
            }
        }
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
