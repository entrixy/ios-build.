import Foundation

/// Widget identifiers disclose neither the server nor the received key. They
/// select a current catalog entry; they are never themselves action authority.
public enum WidgetObjectID {
    public static func forTarget(_ target: ObjectReference) -> String { GuestCrypto.hash(Data(target.id.utf8)) }
    public static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// An actual AppIntent invocation may wait for entry unlock/initial sync, but
/// survives neither a process restart nor expiration. Consume BEFORE dispatch;
/// an unavailable or ambiguous action must never turn into a retry on resume.
public struct WidgetTapQueue {
    public struct Tap: Equatable {
        public let id: UUID
        public let objectID: String
        public let createdAt: Date
    }
    public private(set) var pending: Tap?
    private var seen: [UUID] = []
    public init() {}
    @discardableResult public mutating func enqueue(objectID: String, id: UUID = UUID(), at date: Date = Date()) -> Bool {
        guard WidgetObjectID.valid(objectID), date.timeIntervalSince1970.isFinite, !seen.contains(id) else { return false }
        seen.append(id); if seen.count > 256 { seen.removeFirst(seen.count - 256) }
        pending = Tap(id:id,objectID:objectID,createdAt:date)
        return true
    }
    public mutating func current(at date: Date = Date()) -> Tap? {
        guard let tap = pending else { return nil }
        let age = date.timeIntervalSince(tap.createdAt)
        guard age >= 0, age <= 60 else { pending = nil; return nil }
        return tap
    }
    public mutating func consume(_ id: UUID, at date: Date = Date()) -> Tap? {
        guard let tap = current(at:date), tap.id == id else { return nil }
        pending = nil
        return tap
    }
    public mutating func cancel() { pending = nil }
}
