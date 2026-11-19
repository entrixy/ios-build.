import UIKit

/// A custom over-full-screen presentation leaves the underlying SwiftUI Form
/// mounted. Hide that presenting provider, preserving its prior state, while
/// keeping the separately presented controller outside the hidden subtree.
@MainActor final class NativeModalAccessibilityBoundary {
    private weak var covered: UIView?
    private var previous = false
    func conceal(_ presenter:UIViewController,for dialog:UIViewController) {
        restore()
        guard let view = presenter.viewIfLoaded,let content = dialog.viewIfLoaded,
              !content.isDescendant(of:view) else { return }
        covered = view; previous = view.accessibilityElementsHidden
        view.accessibilityElementsHidden = true
        UIAccessibility.post(notification:.screenChanged,argument:nil)
        #if DEBUG
        print("Native modal AX boundary: presenting provider hidden; dialog outside covered subtree")
        #endif
    }
    func restore() {
        covered?.accessibilityElementsHidden = previous; covered = nil
    }
}
