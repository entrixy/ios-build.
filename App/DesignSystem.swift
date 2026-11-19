import SwiftUI
import UIKit

/// Shared visual rules are documented in docs/IOS_DESIGN_CODE.md.
enum DesignMetrics {
    static let pageInset: CGFloat = 20
    static let sectionGap: CGFloat = 20
    static let actionRadius: CGFloat = 12
    static let primaryHeight: CGFloat = 48
    static let secondaryHeight: CGFloat = 48
    static let actionHorizontalPadding: CGFloat = 14
    static let actionVerticalPadding: CGFloat = 12
    static let dialogPadding: CGFloat = 24
    static let dialogMargin: CGFloat = 16
    static let dialogMaxWidth: CGFloat = 420
    static let dialogOuterInset: CGFloat = 20
    static let dialogGap: CGFloat = 18
    static let dialogActionGap: CGFloat = 12
    static let dialogCorner: CGFloat = 20
    static let dialogDimOpacity = 0.35
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
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignMetrics.actionHorizontalPadding).padding(.vertical, DesignMetrics.actionVerticalPadding)
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
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? (configuration.role == .destructive ? Color.white : Brand.ink) : Brand.secondaryInk)
            .padding(.horizontal, DesignMetrics.actionHorizontalPadding).padding(.vertical, DesignMetrics.actionVerticalPadding)
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

/// Equal-width actions also share the tallest measured height. Long localized
/// labels and Dynamic Type may grow a row without squeezing text to its edges.
struct EqualActionRow<Content:View>: View {
    @Environment(\.layoutDirection) private var direction
    @ViewBuilder let content: () -> Content
    var body: some View { EqualActionLayout(direction:direction) { content() } }
}

private struct EqualActionLayout: Layout {
    let direction: LayoutDirection
    private let gap = DesignMetrics.dialogActionGap
    init(direction:LayoutDirection) { self.direction = direction }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let natural = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = max(0,proposal.width ?? (natural*count+gap*(count-1)))
        let cellWidth = max(0,(width-gap*(count-1))/count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width:cellWidth,height:nil)).height }.max() ?? 0
        return CGSize(width:width,height:max(DesignMetrics.primaryHeight,height))
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        guard !subviews.isEmpty else { return }
        let cellWidth = max(0,(bounds.width-gap*CGFloat(subviews.count-1))/CGFloat(subviews.count))
        for index in subviews.indices {
            let column = direction == .rightToLeft ? subviews.count-1-index : index
            subviews[index].place(at:CGPoint(x:bounds.minX+CGFloat(column)*(cellWidth+gap),y:bounds.minY),anchor:.topLeading,
                proposal:ProposedViewSize(width:cellWidth,height:bounds.height))
        }
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
        }
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


private struct DialogContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value,nextValue()) }
}

/// One content tree for layout, interaction and accessibility. A tall dialog
/// scrolls; constructing two copies of its observed controls in ViewThatFits
/// can leave the accessibility snapshot evaluating both copies indefinitely.
private struct DialogFooterHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value = max(value,nextValue()) }
}

struct AppDialogSurface<Content:View,Footer:View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    private let hasFooter: Bool
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    init(@ViewBuilder content:@escaping () -> Content) where Footer == EmptyView {
        self.content = content; self.footer = { EmptyView() }; hasFooter = false
    }
    init(@ViewBuilder content:@escaping () -> Content,@ViewBuilder footer:@escaping () -> Footer) {
        self.content = content; self.footer = footer; hasFooter = true
    }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(DesignMetrics.dialogDimOpacity).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { }
                    .accessibilityHidden(true)
                VStack(spacing:hasFooter ? DesignMetrics.dialogGap : 0) {
                    let available = max(1,proxy.size.height-2*(DesignMetrics.dialogOuterInset+DesignMetrics.dialogPadding)-(hasFooter ? footerHeight+DesignMetrics.dialogGap : 0))
                    ScrollView {
                        content().frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                            .background(GeometryReader { size in Color.clear.preference(key:DialogContentHeight.self,value:size.size.height) })
                    }.scrollIndicators(.hidden)
                        .frame(height:min(contentHeight > 0 ? contentHeight : available,available))
                        .onPreferenceChange(DialogContentHeight.self) { height in
                            if abs(contentHeight-height) > 0.5 { contentHeight = height }
                        }
                    if hasFooter {
                        footer().frame(maxWidth:.infinity).fixedSize(horizontal:false,vertical:true)
                            .background(GeometryReader { size in Color.clear.preference(key:DialogFooterHeight.self,value:size.size.height) })
                            .onPreferenceChange(DialogFooterHeight.self) { height in
                                if abs(footerHeight-height) > 0.5 { footerHeight = height }
                            }
                    }
                }
                    .padding(DesignMetrics.dialogPadding).frame(width:min(max(0,proxy.size.width-2*DesignMetrics.dialogMargin),DesignMetrics.dialogMaxWidth))
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius:DesignMetrics.dialogCorner))
                    .padding(.vertical,DesignMetrics.dialogOuterInset)
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

            }
        } footer: {
                EqualActionRow {
                    Button(ProductText.string("btn_cancel"), action: cancel).buttonStyle(SecondaryActionStyle())
                    Button(role: destructive ? .destructive : nil, action: confirm) { Text(actionTitle) }
                        .buttonStyle(PrimaryActionStyle())
                }
        }
    }
}


/// A task-local confirmation shares the root dialog's design while remaining
/// above its actual sheet/navigation host. It never inherits hidden content's AX.
private struct TaskDialog<Dialog:View>: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var barrier = UUID()
    @Binding var presented: Bool
    @ViewBuilder let dialog: () -> Dialog
    func body(content: Content) -> some View {
        ZStack {
            content.accessibilityHidden(presented).allowsHitTesting(!presented)
            if presented {
                dialog()
            }
        }
        .navigationBarBackButtonHidden(presented)
        .onAppear { model.setLocalTaskDialog(barrier,presented:presented) }
        .onChange(of:presented) { model.setLocalTaskDialog(barrier,presented:$0) }
        .onChange(of:phase) { if $0 == .background { presented = false; model.setLocalTaskDialog(barrier,presented:false) } }
        .onDisappear { model.setLocalTaskDialog(barrier,presented:false) }
    }
}

extension View {
    func appConfirmationDialog(_ title: String, message: String, actionTitle: String,
                               destructive: Bool = false, isPresented: Binding<Bool>,
                               confirm: @escaping () -> Void) -> some View {
        modifier(TaskDialog(presented:isPresented) {
            AppConfirmationDialog(title:title,message:message,actionTitle:actionTitle,destructive:destructive,
                cancel:{ isPresented.wrappedValue = false },confirm:{ confirm(); isPresented.wrappedValue = false })
        })
    }
    func appMessageDialog(_ title: String, message: String, actionTitle: String,
                          isPresented: Binding<Bool>) -> some View {
        modifier(TaskDialog(presented:isPresented) {
            AppDialogSurface {
                VStack(alignment:.leading,spacing:18) {
                    Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Text(message).fixedSize(horizontal:false,vertical:true)
                }
            } footer: {
                Button(actionTitle) { isPresented.wrappedValue = false }.buttonStyle(PrimaryActionStyle())
            }
        })
    }

}
