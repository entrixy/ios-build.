import Foundation

/// Android AppLock: cold start or more than one minute in the background.
/// This protects entry to the UI; it does not grant or revoke object permissions.
public struct AppEntryLockPolicy {
    private var unlockedThisProcess = false
    private var backgroundAt: TimeInterval?
    public init() {}
    public mutating func background(now: TimeInterval) { backgroundAt = now }
    public mutating func unlocked() { unlockedThisProcess = true; backgroundAt = nil }
    public func requiresUnlock(enabled: Bool, hasCode: Bool, now: TimeInterval) -> Bool {
        guard enabled, hasCode else { return false }
        guard unlockedThisProcess else { return true }
        guard let backgroundAt else { return false }
        guard now.isFinite, backgroundAt.isFinite, backgroundAt >= 0, now >= backgroundAt else { return true }
        return now - backgroundAt > 60
    }
}
