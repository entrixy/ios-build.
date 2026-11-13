import SwiftUI
import EntrixyCore

@main
struct EntrixyApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if let scenario = ActionCaptureScenario.current {
                ActionCaptureRoot(scenario: scenario)
            } else {
                LiveAppRoot()
            }
            #else
            LiveAppRoot()
            #endif
        }
    }
}

private struct LiveAppRoot: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        RootView(initialTab: PreviewRouting.tab, showAddKey: PreviewRouting.addKey)
            .environmentObject(model)
            .task { await model.resume() }
            .onChange(of: phase) { value in
                if value == .active { Task { await model.resume() } }
                else if value == .background { model.suspend() }
            }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: AppTab
    @State private var adding = false
    @State private var input = ""
    private let showAddKeyOnLaunch: Bool

    init(initialTab: AppTab = .control, showAddKey: Bool = false) {
        _selectedTab = State(initialValue: initialTab)
        showAddKeyOnLaunch = showAddKey
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ControlScreen { input = ""; adding = true } }
                .tabItem { Label("Управление", image: "tab-control") }.tag(AppTab.control)
            NavigationStack { SettingsScreen() }
                .tabItem { Label("Настройки", image: "tab-settings") }.tag(AppTab.settings)
            NavigationStack { OwnerGuestsScreen() }.tabItem { Label("Гости", image: "tab-guests") }.tag(AppTab.guests)
            NavigationStack { JournalScreen() }
                .tabItem { Label("Журнал", image: "tab-journal") }.tag(AppTab.journal)
        }
        .tint(Brand.primary)
        .task {
            if showAddKeyOnLaunch {
                try? await Task.sleep(nanoseconds: 400_000_000)
                adding = true
            }
        }
        .onOpenURL { url in
            do {
                input = try AccessLink.incomingText(url.absoluteString)
                adding = true
            } catch { model.errorMessage = "В этой ссылке не найден поддерживаемый ключ Entrixy." }
        }
        .sheet(isPresented: $adding) { KeyImportScreen(input: $input) }
        .alert("Entrixy", isPresented: Binding(get: { model.errorMessage != nil && !adding }, set: { if !$0 && !adding { model.errorMessage = nil } })) {
            Button("Понятно") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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

struct BrandLogo: View {
    var body: some View {
        Image("brand-horizontal").resizable().scaledToFit().frame(width: 120, height: 28)
            .accessibilityLabel("Entrixy")
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
