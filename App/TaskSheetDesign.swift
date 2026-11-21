import SwiftUI
import UIKit

/// The same heading and first-content inset for every application task sheet.
/// Native photo/file/camera pickers and ordinary pushed pages keep their own bars.
struct TaskSheetHeader<Trailing:View>: View {
    let title:String
    var identifier = "task-sheet-title"
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing:12) {
            Text(title).font(.title2.weight(.semibold))
                .fixedSize(horizontal:false,vertical:true)
                .frame(maxWidth:.infinity,alignment:.leading)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier(identifier)
                .padding(.vertical,DesignMetrics.sheetTitlePadding)
            trailing()
        }.frame(minHeight:DesignMetrics.iconActionSize)
            .padding(.horizontal,DesignMetrics.pageInset)
            .padding(.vertical,DesignMetrics.sheetHeaderPadding)
            .background(Color(uiColor:.systemGroupedBackground))
    }
}

private struct TaskSheetTitle<Trailing:View>: ViewModifier {
    let title:String
    let form:Bool
    let identifier:String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder private func inset(_ content:Content) -> some View {
        if form {
            if #available(iOS 17.0,*) {
                content.contentMargins(.top,DesignMetrics.pageInset,for:.scrollContent)
            } else { content }
        } else { content }
    }
    func body(content:Content) -> some View {
        inset(content).toolbar(.hidden,for:.navigationBar)
            .safeAreaInset(edge:.top,spacing:0) {
                TaskSheetHeader(title:title,identifier:identifier,trailing:trailing)
            }
    }
}

extension View {
    func taskSheetTitle(_ title:String,form:Bool = false,identifier:String = "task-sheet-title") -> some View {
        modifier(TaskSheetTitle(title:title,form:form,identifier:identifier,trailing:{ EmptyView() }))
    }
    func taskSheetTitle<Trailing:View>(_ title:String,form:Bool = false,identifier:String = "task-sheet-title",@ViewBuilder trailing:@escaping () -> Trailing) -> some View {
        modifier(TaskSheetTitle(title:title,form:form,identifier:identifier,trailing:trailing))
    }
}

/// A fixed 48pt cell never grows with its glyph. Each wrapped row, including
/// the short final row, is centred independently without reordering actions.
struct CenteredIconActions<Content:View>: View {
    @Environment(\.layoutDirection) private var direction
    @ViewBuilder var content: () -> Content
    var body: some View { CenteredIconActionLayout(direction:direction) { content() } }
}

private struct CenteredIconActionLayout: Layout {
    let direction:LayoutDirection
    private let side = DesignMetrics.iconActionSize
    private let gap:CGFloat = 8
    private func columns(_ width:CGFloat,_ count:Int) -> Int { max(1,min(count,Int((width+gap)/(side+gap)))) }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? CGFloat(subviews.count)*(side+gap)-gap
        let rows = (subviews.count+columns(width,subviews.count)-1)/columns(width,subviews.count)
        return CGSize(width:width,height:CGFloat(rows)*(side+gap)-gap)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let count = columns(bounds.width,subviews.count)
        for index in subviews.indices {
            let row = index/count,offset = index%count
            let rowCount = min(count,subviews.count-row*count)
            let order = direction == .rightToLeft ? rowCount-1-offset : offset
            let rowWidth = CGFloat(rowCount)*(side+gap)-gap
            subviews[index].place(at:CGPoint(x:bounds.midX-rowWidth/2+CGFloat(order)*(side+gap),y:bounds.minY+CGFloat(row)*(side+gap)),anchor:.topLeading,proposal:ProposedViewSize(width:side,height:side))
        }
    }
}

struct SelectedOptionStyle: ButtonStyle {
    let selected:Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal,DesignMetrics.actionHorizontalPadding).padding(.vertical,12)
            .frame(maxWidth:.infinity,minHeight:DesignMetrics.secondaryHeight)
            .foregroundStyle(enabled ? (selected ? AppPalette.selected : Brand.ink) : AppPalette.disabledText)
            .background(enabled ? (selected ? AppPalette.selectedSurface : AppPalette.secondary) : AppPalette.disabledSurface,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(enabled ? (selected ? AppPalette.selected : Brand.ink) : AppPalette.disabledBorder,lineWidth:selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius:12))
            .opacity(configuration.isPressed && enabled ? 0.85 : 1)
    }
}

/// Functional mode choices use a visible selected colour. Navigation tabs are
/// separate controls and retain their established neutral navigation styling.
struct SelectedModePicker: UIViewRepresentable {
    let options:[(value:String,title:String)]
    @Binding var selection:String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> UISegmentedControl {
        let view=UISegmentedControl()
        view.addTarget(context.coordinator,action:#selector(Coordinator.changed(_:)),for:.valueChanged)
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
    }
    func updateUIView(_ view:UISegmentedControl,context:Context) {
        context.coordinator.parent=self
        if view.numberOfSegments != options.count { view.removeAllSegments();for (index,option) in options.enumerated() { view.insertSegment(withTitle:option.title,at:index,animated:false) } }
        for (index,option) in options.enumerated() { view.setTitle(option.title,forSegmentAt:index) }
        view.selectedSegmentIndex=options.firstIndex(where:{ $0.value == selection }) ?? UISegmentedControl.noSegment
        view.isEnabled=enabled
        view.selectedSegmentTintColor=UIColor(enabled ? AppPalette.selected : AppPalette.disabledSurface)
        view.setTitleTextAttributes([.foregroundColor:UIColor(Brand.ink),.font:UIFont.preferredFont(forTextStyle:.caption1)],for:.normal)
        view.setTitleTextAttributes([.foregroundColor:UIColor.systemBackground,.font:UIFont.preferredFont(forTextStyle:.caption1)],for:.selected)
        view.setTitleTextAttributes([.foregroundColor:UIColor(AppPalette.disabledText)],for:.disabled)
        view.setTitleTextAttributes([.foregroundColor:UIColor(AppPalette.disabledText)],for:[.selected,.disabled])
    }
    final class Coordinator:NSObject {
        var parent:SelectedModePicker
        init(_ parent:SelectedModePicker) { self.parent=parent }
        @objc func changed(_ view:UISegmentedControl) {
            guard view.isEnabled,parent.options.indices.contains(view.selectedSegmentIndex) else { return }
            parent.selection=parent.options[view.selectedSegmentIndex].value
        }
    }
}
