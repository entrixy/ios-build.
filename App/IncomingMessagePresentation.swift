import SwiftUI
import UIKit

/// Android's incoming-message overlay, presented above the actual current task
/// host. Its encrypted unread record is the queue; presentation alone is not read.
struct IncomingMessagePresenter: UIViewControllerRepresentable {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: MessageManager
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(); controller.app = app; controller.manager = manager; return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.app = app; controller.manager = manager; controller.schedule()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }

    @MainActor final class Controller: UIViewController {
        weak var app: AppModel?
        weak var manager: MessageManager?
        private var notice: UIViewController?
        private var noticeID: String?
        private var dismissing = false
        private var scheduled = false
        private var stopped = false
        private let boundary = NativeModalAccessibilityBoundary()
        override func loadView() {
            view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); schedule() }
        func schedule() {
            guard !scheduled, !stopped else { return }; scheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }; self.scheduled = false
                if !self.stopped { self.refresh() }
            }
        }
        private func refresh() {
            guard let app, let manager else { return }
            if notice != nil {
                let stillUnread = app.incomingMessages.contains { row in
                    row.id == noticeID && row.readAt == nil && (try? manager.text(row)) != nil
                }
                if !app.canManageGuestAccess || app.incomingMessagePromptID != noticeID || !stillUnread { dismissNotice() }
                return
            }
            guard let window = view.window, window.windowScene?.activationState == .foregroundActive,
                  let message = manager.nextUnreadNotice(), let root = window.rootViewController else { return }
            var presenter = root
            while let child = presenter.presentedViewController { presenter = child }
            // System permission/confirmation UI owns the foreground until done.
            guard !(presenter is UIAlertController), !presenter.isBeingDismissed,
                  !presenter.isBeingPresented, presenter.viewIfLoaded?.window != nil else { return }
            let id = message.id
            let dialog = IncomingMessageDialog(manager:manager,message:message) { [weak self] in self?.close(id) }
                .environmentObject(app)
            let host = UIHostingController(rootView:dialog)
            host.view.backgroundColor = .clear; host.view.accessibilityViewIsModal = true
            host.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
            host.modalPresentationStyle = .overFullScreen; host.modalTransitionStyle = .crossDissolve
            notice = host; noticeID = id; app.incomingMessagePromptID = id
            presenter.present(host,animated:true) { [weak self,weak host,weak presenter] in
                guard let self,let host,let presenter,self.notice === host else { return }
                boundary.conceal(presenter,for:host)
            }
        }
        private func close(_ id: String) {
            guard let app, let manager, noticeID == id, app.incomingMessagePromptID == id,
                  manager.markRead(id) else { return }
            // Persist before dismissal/ack, but never hold Close behind a network reply.
            Task { await manager.retryAcknowledgements() }
            dismissNotice()
        }
        private func dismissNotice() {
            guard let notice, !dismissing else { return }; dismissing = true
            let previous = noticeID
            notice.dismiss(animated:true) { [weak self] in
                guard let self else { return }
                self.boundary.restore()
                self.notice = nil; self.noticeID = nil; self.dismissing = false
                if self.app?.incomingMessagePromptID == previous { self.app?.incomingMessagePromptID = nil }
                self.schedule()
            }
        }
        func stop() {
            stopped = true
            let previous = noticeID
            notice?.dismiss(animated:false); notice = nil; noticeID = nil; boundary.restore()
            if let previous, app?.incomingMessagePromptID == previous { app?.incomingMessagePromptID = nil }
        }
    }
}

private struct IncomingMessageDialog: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var manager: MessageManager
    let message: SavedMessage
    let close: () -> Void
    var body: some View {
        AppDialogSurface {
            VStack(alignment:.leading,spacing:18) {
                Text(ProductText.string("msg_incoming_title")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("incoming-message-title")
                if let sender = manager.sender(message) {
                    Text(sender).font(.subheadline.weight(.semibold))
                } else if let guest = app.guests.first(where:{ $0.id == message.guestID }) {
                    Text(guest.invite.server).font(.subheadline).foregroundStyle(Brand.secondaryInk)
                }
                if let text = try? manager.text(message) {
                    Text(productLinkified(text)).textSelection(.enabled).privacySensitive()
                        .accessibilityIdentifier("incoming-message-body")
                }
                if let error = manager.message { Text(ProductText.systemMessage(error)).font(.footnote).foregroundStyle(AppPalette.destructive) }
            }.foregroundStyle(Brand.ink)
        } footer: {
                Button(ProductText.string("btn_close"),action:close).buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("incoming-message-close")
        }.tint(Brand.primary)
    }
}
