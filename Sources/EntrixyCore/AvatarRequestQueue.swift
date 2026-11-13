import Foundation

/// Serialize optional image reads so a large key cannot flood the event buffer.
public actor AvatarRequestQueue {
    private var pending: [Int] = []
    private var waiting: (id: Int, sent: TimeInterval)?

    public init() {}
    public func replace(_ ids: [Int]) {
        let valid = Set(ids.filter { $0 > 0 })
        if let active = waiting, !valid.contains(active.id) { waiting = nil }
        pending = valid.filter { $0 != waiting?.id }.sorted()
    }
    public func next(now: TimeInterval = Date().timeIntervalSince1970) -> Int? {
        if let active = waiting, now - active.sent < 10 { return nil }
        waiting = nil
        guard !pending.isEmpty else { return nil }
        let id = pending.removeFirst()
        waiting = (id, now)
        return id
    }
    public func received(_ id: Int) { if waiting?.id == id { waiting = nil } }
}
