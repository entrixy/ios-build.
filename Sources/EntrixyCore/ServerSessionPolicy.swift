import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Platform composition hook used only by server API sessions. Camera and
/// phone-webhook sessions keep their own origin and local-network boundaries.
public final class ServerSessionPolicy: @unchecked Sendable {
    public static let shared = ServerSessionPolicy()
    private let lock = NSLock()
    private var handler: (@Sendable (URLSessionConfiguration) -> Void)?
    private var authorization: (@Sendable (URL) throws -> Void)?
    private var privacyEnforced = false
    public var networkPrivacyEnforced: Bool { lock.lock(); defer { lock.unlock() }; return privacyEnforced }
    private var observers: [UUID:@Sendable () -> Void] = [:]
    private init() {}
    public func install(_ handler: @escaping @Sendable (URLSessionConfiguration) -> Void,
                        authorize: @escaping @Sendable (URL) throws -> Void = { _ in },
                        networkPrivacyEnforced: Bool = false) {
        lock.lock(); self.handler = handler; authorization = authorize; privacyEnforced = networkPrivacyEnforced; lock.unlock()
        resetSessions()
    }
    func configure(_ configuration: URLSessionConfiguration) {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(configuration)
    }
    func check(_ url: URL) throws {
        lock.lock(); let authorization = self.authorization; lock.unlock()
        try authorization?(url)
    }
    func observeReset(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID(); lock.lock(); observers[id] = handler; lock.unlock(); return id
    }
    func removeObserver(_ id: UUID) { lock.lock(); observers.removeValue(forKey:id); lock.unlock() }
    public func resetSessions() {
        lock.lock(); let callbacks = Array(observers.values); lock.unlock()
        callbacks.forEach { $0() }
    }
    // Standalone Core tests can restore the uninstalled composition boundary.
    func clear() { lock.lock(); handler = nil; authorization = nil; privacyEnforced = false; lock.unlock(); resetSessions() }
}

/// Owns one server client's session and invalidates old HTTP/WSS tasks on a
/// privacy change. There is no resubmission or physical-action retry here.
final class ServerHTTPSession: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var current: URLSession
    private var observer: UUID?
    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        current = Self.build(self.configuration)
        observer = ServerSessionPolicy.shared.observeReset { [weak self] in self?.reset() }
    }
    deinit {
        if let observer { ServerSessionPolicy.shared.removeObserver(observer) }
        current.invalidateAndCancel()
    }
    func session(for url: URL) throws -> URLSession {
        // Take the session first, then check the latest rule. If a rule changes
        // afterwards, that retained old session is the one reset/cancelled.
        lock.lock(); let value = current; lock.unlock()
        try ServerSessionPolicy.shared.check(url)
        return value
    }
    private func reset() {
        let replacement = Self.build(configuration)
        lock.lock(); let old = current; current = replacement; lock.unlock()
        old.invalidateAndCancel()
    }
    private static func build(_ configuration: URLSessionConfiguration) -> URLSession {
        let copy = configuration.copy() as! URLSessionConfiguration
        ServerSessionPolicy.shared.configure(copy)
        return URLSession(configuration:copy,delegate:NoRedirects(),delegateQueue:nil)
    }
}
