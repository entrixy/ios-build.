import Foundation

/// A UI target is never just a numeric object ID. Two servers/received keys can
/// contain the same number and must retain independent settings and commands.
public enum ObjectReference: Codable, Hashable, Identifiable {
    case owned(server: String, objectID: UUID)
    case received(guestID: String, objectID: String)

    public var id: String {
        switch self {
        case let .owned(server, objectID): return "owner:" + server + ":" + objectID.uuidString.lowercased()
        case let .received(guestID, objectID):
            return "guest:" + GuestCrypto.hash(Data(guestID.utf8)) + ":" + GuestCrypto.base64URL(Data(objectID.utf8))
        }
    }
    public func validate() throws {
        switch self {
        case let .owned(server, _):
            guard server == (try GuestInvite.normalizeServer(server)) else { throw GuestCrypto.Failure.invalidEnvelope }
        case let .received(guestID, objectID):
            guard !guestID.isEmpty, guestID.utf8.count <= 1024, !objectID.isEmpty, objectID.utf8.count <= 256 else {
                throw GuestCrypto.Failure.invalidEnvelope
            }
        }
    }
}

public struct ReceivedObjectPresentation: Codable, Equatable {
    public var label: String?
    public var hidden: Bool
    public var avatarPreset: Int?
    public var avatarCipher: String?
    public init(label: String? = nil, hidden: Bool = false) { self.label = label; self.hidden = hidden }
}

/// Local presentation only. Never changes owner metadata, scope, templates,
/// signed grants, token lifetime, command readiness or command replay guards.
public struct ObjectCatalogPreferences: Codable, Equatable {
    public var order: [ObjectReference]
    public var received: [String: ReceivedObjectPresentation]
    public init(order: [ObjectReference] = [], received: [String: ReceivedObjectPresentation] = [:]) {
        self.order = order; self.received = received
    }
    public func validate() throws {
        guard order.count <= 4000, Set(order).count == order.count, received.count <= 4000,
              received.allSatisfy({ key, value in
                  key.hasPrefix("guest:") && key.utf8.count <= 512 &&
                  (value.avatarPreset.map { (0...7).contains($0) } ?? true) &&
                  (value.avatarCipher.map { $0.utf8.count <= 1_048_576 && value.avatarPreset == nil } ?? true) &&
                  (value.label == nil || (value.label!.utf8.count <= 512 && !value.label!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
              }) else { throw GuestCrypto.Failure.invalidEnvelope }
        for target in order { try target.validate() }
    }
    public func sorted<T>(_ values: [T], reference: (T) -> ObjectReference) -> [T] {
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted {
            let lhs = ranks[reference($0.element)] ?? Int.max
            let rhs = ranks[reference($1.element)] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
    public func presentation(for target: ObjectReference) -> ReceivedObjectPresentation {
        received[target.id] ?? ReceivedObjectPresentation()
    }
    public mutating func rename(_ target: ObjectReference, label: String) throws {
        guard case .received = target else { throw GuestCrypto.Failure.invalidEnvelope }
        try target.validate()
        var value = presentation(for: target)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        value.label = trimmed.isEmpty ? nil : trimmed
        received[target.id] = value
        try validate()
    }
    public mutating func hide(_ target: ObjectReference) throws {
        guard case .received = target else { throw GuestCrypto.Failure.invalidEnvelope }
        try target.validate()
        // Android Settings removes this object's local label when hiding it.
        // Re-import reveals the owner's original name, not an abandoned alias.
        var value = presentation(for: target); value.hidden = true; value.label = nil
        received[target.id] = value
        try validate()
    }
    public mutating func reveal(_ targets: [ObjectReference]) {
        for target in targets where received[target.id] != nil { received[target.id]?.hidden = false }
    }
    public mutating func removeGuest(_ guestID: String) {
        let prefix = "guest:" + GuestCrypto.hash(Data(guestID.utf8)) + ":"
        received = received.filter { !$0.key.hasPrefix(prefix) }
        order.removeAll { if case let .received(id, _) = $0 { return id == guestID }; return false }
    }
    /// Keep current-device choices on conflicts. Restored targets are appended;
    /// identities are stable across a normal backup, not remapped to array indices.
    public func merging(_ incoming: Self?) throws -> Self {
        guard let incoming else { return self }
        try incoming.validate()
        var result = self
        let existing = Set(order)
        result.order += incoming.order.filter { !existing.contains($0) }
        result.received.merge(incoming.received) { current, _ in current }
        try result.validate()
        return result
    }
}
