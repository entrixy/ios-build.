import SwiftUI
import UIKit

/// Shared visual rules are documented in docs/IOS_DESIGN_CODE.md.
enum DesignMetrics {
    static let pageInset: CGFloat = 20
    static let sectionGap: CGFloat = 20
    static let actionRadius: CGFloat = 12
    static let primaryHeight: CGFloat = 48
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
            .foregroundStyle(isEnabled ? (configuration.role == .destructive ? Color.white : Color(uiColor: .systemBackground)) : Brand.secondaryInk)
            .frame(maxWidth: .infinity).frame(minHeight: DesignMetrics.primaryHeight)
            .background(isEnabled ? (configuration.role == .destructive ? AppPalette.destructive : Brand.ink) : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: DesignMetrics.actionRadius))
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

enum AppPalette {
    static let destructive = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.40, blue: 0.36, alpha: 1) : UIColor(red: 186/255, green: 26/255, blue: 26/255, alpha: 1) })
    static let secondary = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.23, alpha: 1) : UIColor(red: 226/255, green: 227/255, blue: 237/255, alpha: 1) })
}
struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? (configuration.role == .destructive ? Color.white : Brand.ink) : Brand.secondaryInk)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: DesignMetrics.secondaryHeight)
            .background(isEnabled ? (configuration.role == .destructive ? AppPalette.destructive : AppPalette.secondary) : Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: DesignMetrics.actionRadius))
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
    /// Keep the system's grouped-list corner mask outside the actual button.
    /// A zero-inset 48pt row becomes a capsule on iOS 26 despite our 12pt shape.
    func actionListRow() -> some View {
        padding(.vertical, 16).listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    @ViewBuilder func compactListSections() -> some View {
        if #available(iOS 17.0, *) { listSectionSpacing(0) }
        else { self }
    }

    func sheetDismissFooter(_ title: String = ProductText.string("btn_cancel"), disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        modifier(SheetDismissFooter(title: title, disabled: disabled, action: action))
    }
}

/// Android rejects an unavailable card tap in place, without a modal or command retry.
struct ActionRejectionFeedback: ViewModifier {
    let rejection: ActionTapRejection?
    @State private var highlighted = false
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(uiColor: .systemRed).opacity(highlighted ? 0.15 : 0))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color(uiColor: .systemRed).opacity(highlighted ? 1 : 0), lineWidth: 2))
                .allowsHitTesting(false)
        }
        .task(id: rejection?.id) {
            highlighted = false
            guard let rejection else { return }
            highlighted = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            UIAccessibility.post(notification: .announcement, argument: rejection.message)
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            highlighted = false
        }
    }
}


/// Common centered Android dialog surface; task forms retain their own sheets.
struct AppDialogSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { }
                    .accessibilityHidden(true)
                ViewThatFits(in: .vertical) {
                    content()
                    ScrollView { content() }
                }.padding(24).frame(width: min(max(0, proxy.size.width - 32), 420))
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .padding(.vertical, 20)
                    .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Shared compact confirmation. Buttons use the same filled styles as forms.
struct AppConfirmationDialog: View {
    let title: String
    let message: String
    let actionTitle: String
    var destructive = false
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        AppDialogSurface {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(ProductText.string("btn_cancel"), action: cancel).buttonStyle(SecondaryActionStyle())
                    Button(role: destructive ? .destructive : nil, action: confirm) { Text(actionTitle) }
                        .buttonStyle(PrimaryActionStyle())
                }
            }
        }
    }
}
