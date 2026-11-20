import Foundation
import UserNotifications
import EntrixyCore

extension Notification.Name { static let entrixyAutomationFocus = Notification.Name("entrixy.automation.focus") }

/// A notification is a navigation hint, never a queued physical command.
/// Only a current protected card tap can act after the person returns.
@MainActor enum AutomationNotifications {
    static func show(label: String, target: ObjectReference) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized,.provisional,.ephemeral].contains(settings.authorizationStatus) else { return }
        AppNotificationRouting.shared.install()
        let content = UNMutableNotificationContent()
        content.title = String(label.prefix(128))
        content.body = ProductText.string("ios_auto_foreground_notice")
        content.sound = AppSoundCenter.shared.notificationSound(.geo)
        content.categoryIdentifier = "entrixy.automation"
        content.userInfo = ["object":WidgetObjectID.forTarget(target)]
        // One OS notification per target, no unbounded arrivals list.
        let identifier = "entrixy.automation." + WidgetObjectID.forTarget(target)
        try? await center.add(UNNotificationRequest(identifier:identifier,content:content,trigger:nil))
    }
}

@MainActor final class AppNotificationRouting {
    static let shared = AppNotificationRouting()
    var cancelled: ((String) -> Void)?
    private var delegate: UnifiedNoticeDelegate?
    func install() {
        if delegate == nil {
            delegate = UnifiedNoticeDelegate { [weak self] id in self?.cancelled?(id) }
        }
        UNUserNotificationCenter.current().delegate = delegate
    }
}

private final class UnifiedNoticeDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let cancelled: @MainActor (String) -> Void
    init(cancelled: @escaping @MainActor (String) -> Void) { self.cancelled = cancelled }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.trigger is UNPushNotificationTrigger {
            Task { @MainActor in
                _ = LiveAppRuntime.model().remoteNotifications.receive(notification.request.content.userInfo)
                completionHandler([]) // Actual decrypted-message path owns its sound/dialog.
            }
        } else { completionHandler([.banner,.sound]) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        Task { @MainActor in
            if request.trigger is UNPushNotificationTrigger {
                _ = LiveAppRuntime.model().remoteNotifications.receive(request.content.userInfo)
            } else if response.actionIdentifier == "entrixy.cancel-call" { cancelled(request.identifier) }
            else if ["entrixy.automation","entrixy.guest-call"].contains(request.content.categoryIdentifier), response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                NotificationCenter.default.post(name:.entrixyAutomationFocus,object:nil)
            }
            completionHandler()
        }
    }
}
