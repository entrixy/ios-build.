import SwiftUI
import WidgetKit

private struct ControlContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value,nextValue()) }
}

@MainActor final class HomeWidgetPresence: ObservableObject {
    @Published private(set) var installed: Bool?
    func refresh() {
        guard #available(iOS 17.0, *) else { installed = nil; return }
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            Task { @MainActor in
                if case .success(let widgets) = result { self?.installed = widgets.contains { $0.kind == WidgetCatalog.kind } }
            }
        }
    }
}

struct HomeLocationWarning: View {
    @ObservedObject var sensors: AutomationSensors
    var body: some View {
        TimelineView(.periodic(from:.now,by:10)) { context in
            if sensors.locationUnreliable(at:context.date) {
                VStack(alignment:.leading,spacing:8) {
                    Label(ProductText.string("home_geo_inaccurate_title"),systemImage:"location.slash").font(.headline)
                        .foregroundStyle(AppPalette.destructive)
                    Text(ProductText.string("home_geo_inaccurate_body")).font(.subheadline).foregroundStyle(Brand.ink)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                    .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
                    .accessibilityIdentifier("home-location-quality")
            }
        }
    }
}

/// Android's bottom hint appears only when the whole action list fits and no
/// object widget exists. It adds no second panel or navigation control.
struct HomeWidgetHint: ViewModifier {
    @StateObject private var presence = HomeWidgetPresence()
    @Environment(\.scenePhase) private var phase
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ControlContentHeight.self) { contentHeight = $0 }
            .background(GeometryReader { proxy in
                Color.clear.onAppear { viewportHeight = proxy.size.height }.onChange(of:proxy.size.height) { viewportHeight = $0 }
            })
            .overlay(alignment:.bottom) {
                if presence.installed == false, contentHeight > 0, contentHeight + 60 <= viewportHeight {
                    Text(ProductText.string("home_widget_hint")).font(.caption).foregroundStyle(Brand.secondaryInk)
                        .multilineTextAlignment(.center).padding(.horizontal,24).padding(.vertical,12)
                        .allowsHitTesting(false).accessibilityIdentifier("home-widget-hint")
                }
            }.onAppear { presence.refresh() }.onChange(of:phase) { if $0 == .active { presence.refresh() } }
    }
}

extension View {
    func measureControlContent() -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key:ControlContentHeight.self,value:proxy.size.height) })
    }
}
