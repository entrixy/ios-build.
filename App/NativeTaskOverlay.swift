import SwiftUI
import UIKit

/// Isolates a first-appearance modal's accessibility tree from the underlying
/// SwiftUI List. The dialog itself keeps the shared native design and actions.
struct NativeTaskOverlay<Dialog:View>: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var phase
    let isPresented: Bool
    @ViewBuilder let content: () -> Dialog
    func makeUIViewController(context:Context) -> NativeTaskOverlayController { NativeTaskOverlayController() }
    func updateUIViewController(_ controller:NativeTaskOverlayController,context:Context) {
        controller.shown = isPresented && phase == .active
        controller.content = AnyView(content()); controller.schedule()
    }
    static func dismantleUIViewController(_ controller:NativeTaskOverlayController,coordinator:()) { controller.stop() }
}

@MainActor final class NativeTaskOverlayController: UIViewController {
    var shown = false
    var content: AnyView?
    private var host: UIViewController?
    private var scheduled = false
    private var dismissing = false
    private var stopped = false
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); schedule() }
    func schedule() {
        guard !scheduled, !stopped else { return }; scheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }; self.scheduled = false
            if !self.stopped { self.refresh() }
        }
    }
    private func refresh() {
        if let host {
            guard !shown, !dismissing else { return }; dismissing = true
            host.dismiss(animated:true) { [weak self] in
                self?.host = nil; self?.dismissing = false; self?.schedule()
            }
            return
        }
        guard shown, let content, let window = view.window,
              window.windowScene?.activationState == .foregroundActive,
              var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIAlertController), !presenter.isBeingPresented,
              !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil else { return }
        let next = UIHostingController(rootView:content)
        next.view.backgroundColor = .clear; next.view.accessibilityViewIsModal = true
        next.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        next.modalPresentationStyle = .overFullScreen; next.modalTransitionStyle = .crossDissolve
        host = next; presenter.present(next,animated:true)
    }
    func stop() { stopped = true; host?.dismiss(animated:false); host = nil }
}
