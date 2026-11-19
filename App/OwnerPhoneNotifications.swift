import Foundation
import UserNotifications

@MainActor protocol OwnerPhoneNoticePosting: AnyObject {
    var cancelled: ((String) -> Void)? { get set }
    func show(id: String, guest: String, object: String) async -> Bool
    func remove(id: String)
}

@MainActor final class OwnerPhoneNotifications: OwnerPhoneNoticePosting {
    var cancelled: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings()
        if status.authorizationStatus == .notDetermined { return (try? await center.requestAuthorization(options: [.alert,.sound])) ?? false }
        return [.authorized,.provisional,.ephemeral].contains(status.authorizationStatus)
    }
    func show(id: String, guest: String, object: String) async -> Bool {
        let settings = await center.notificationSettings()
        guard [.authorized,.provisional,.ephemeral].contains(settings.authorizationStatus) else { return false }
        AppNotificationRouting.shared.cancelled = { [weak self] id in self?.cancelled?(id) }
        AppNotificationRouting.shared.install()
        let action = UNNotificationAction(identifier: "entrixy.cancel-call", title: ProductText.string("btn_cancel"), options: [])
        var categories = await center.notificationCategories()
        categories = Set(categories.filter { $0.identifier != "entrixy.guest-call" })
        categories.insert(UNNotificationCategory(identifier: "entrixy.guest-call", actions: [action], intentIdentifiers: [], options: []))
        center.setNotificationCategories(categories)
        let content = UNMutableNotificationContent()
        content.title = ProductText.string("notify_call_title", guest)
        content.body = ProductText.string("notify_call_big", guest, object)
        content.sound = AppSoundCenter.shared.notificationSound(.incall); content.categoryIdentifier = "entrixy.guest-call"
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)); return true }
        catch { return false }
    }
    func remove(id: String) { center.removePendingNotificationRequests(withIdentifiers: [id]); center.removeDeliveredNotifications(withIdentifiers: [id]) }
}
