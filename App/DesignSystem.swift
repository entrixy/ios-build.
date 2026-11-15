import SwiftUI

/// Shared visual rules are documented in docs/IOS_DESIGN_CODE.md.
enum DesignMetrics {
    static let pageInset: CGFloat = 20
    static let sectionGap: CGFloat = 20
    static let actionRadius: CGFloat = 14
    static let primaryHeight: CGFloat = 54
    static let secondaryHeight: CGFloat = 48
}

struct AppField<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.secondaryInk)
                .accessibilityHidden(true)
            content.accessibilityLabel(Text(title))
        }.padding(.vertical, 4)
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .foregroundStyle(isEnabled ? Color(uiColor: .systemBackground) : Brand.secondaryInk)
            .frame(maxWidth: .infinity).frame(minHeight: DesignMetrics.primaryHeight)
            .background(isEnabled ? Brand.ink : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: DesignMetrics.actionRadius))
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? (configuration.role == .destructive ? Color(uiColor: .systemRed) : Brand.ink) : Brand.secondaryInk)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: DesignMetrics.secondaryHeight)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: DesignMetrics.actionRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.actionRadius)
                .strokeBorder(isEnabled && configuration.role == .destructive ? Color(uiColor: .systemRed) : Brand.secondaryInk.opacity(0.45), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct CardActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct ActionButtonLabel: View {
    let title: String
    var busy = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small).tint(isEnabled ? Color(uiColor: .systemBackground) : Brand.secondaryInk) }
            Text(title).multilineTextAlignment(.center)
        }.padding(.horizontal, 12)
    }
}

private struct SheetDismissFooter: ViewModifier {
    let title: String
    let disabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button(title, role: .cancel, action: action)
                    .buttonStyle(SecondaryActionStyle()).disabled(disabled)
                    .padding(.horizontal, DesignMetrics.pageInset).padding(.vertical, 12)
                #if DEBUG && targetEnvironment(simulator)
                if ActionCaptureScenario.current != nil { CaptureEnvironmentBadge() }
                #endif
            }.background(Color(uiColor: .systemGroupedBackground))
        }.interactiveDismissDisabled(disabled)
    }
}

extension View {
    func sheetDismissFooter(_ title: String = "Отмена", disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        modifier(SheetDismissFooter(title: title, disabled: disabled, action: action))
    }
}
