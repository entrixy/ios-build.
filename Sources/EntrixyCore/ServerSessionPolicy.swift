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
    private init() {}
    public func install(_ handler: @escaping @Sendable (URLSessionConfiguration) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func configure(_ configuration: URLSessionConfiguration) {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(configuration)
    }
}
