import SwiftUI
import EntrixyCore

struct AppNavigationState: Equatable {
    let hasActions: Bool
    let hasOwnObjects: Bool
    let canDelegate: Bool
    var tabs: [AppTab] {
        (hasActions ? [.control] : []) + [.settings] + (hasOwnObjects || canDelegate ? [.guests] : []) + [.journal]
    }
    func resolve(_ tab: AppTab) -> AppTab { tabs.contains(tab) ? tab : .settings }
}

extension AppModel {
    var navigationState: AppNavigationState {
        let owned = owners.contains { !($0.objects ?? []).isEmpty || !($0.issuedKeys ?? []).isEmpty }
        return AppNavigationState(hasActions: !controlObjects.isEmpty,
            hasOwnObjects: owned, canDelegate: guests.contains { (1...5).contains($0.incomingDepth ?? 0) })
    }
}

/// Single full-width surface shared by roots and their NavigationStack destinations.
struct AppBottomNavigation: View {
    @AppStorage("entrixy.language") private var language = ""
    @Binding var selection: AppTab
    var tabs: [AppTab] = [.control, .settings, .guests, .journal]
    var onSelect: () -> Void = {}
    private func label(_ tab: AppTab) -> String {
        switch tab { case .control: return ProductText.string("tab_actions"); case .settings: return ProductText.string("tab_settings"); case .guests: return ProductText.string("tab_guests"); case .journal: return ProductText.string("tab_journal") }
    }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    Button { selection = tab; onSelect() } label: {
                        VStack(spacing: 5) {
                            Image("tab-" + tab.rawValue).resizable().scaledToFit().frame(width: 26, height: 26)
                            Text(label(tab)).font(.system(size: 11, weight: selection == tab ? .semibold : .regular))
                        }.frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(selection == tab ? Brand.ink : Brand.secondaryInk)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("main-tab-" + tab.rawValue)
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
        }.background(Color(uiColor: .secondarySystemGroupedBackground).ignoresSafeArea(edges: .bottom)).id(language)
    }
}
