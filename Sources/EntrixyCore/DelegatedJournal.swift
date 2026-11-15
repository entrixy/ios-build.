import Foundation

/// Authenticated delegate-list reports action requests, not confirmed physical outcomes.
public struct DelegatedJournalEvent: Equatable {
    public let id: Int
    public let numberID: Int
    public let group: String
    public let epoch: Int64
}

public struct DelegatedJournalLedger: Codable, Equatable {
    public private(set) var hosts: [String: [Int]] = [:]
    public init() {}
    public func validate() throws {
        guard hosts.count <= 1000 else { throw GuestCrypto.Failure.invalidEnvelope }
        for (host, ids) in hosts {
            guard try GuestInvite.normalizeServer(host) == host, ids.count <= 500,
                  ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { throw GuestCrypto.Failure.invalidEnvelope }
        }
    }
    public mutating func accept(_ events: [DelegatedJournalEvent], server: String) throws -> [DelegatedJournalEvent] {
        try validate()
        let host = try GuestInvite.normalizeServer(server)
        let seen = Set(hosts[host] ?? [])
        let fresh = events.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty else { return [] }
        hosts[host] = Array(Set((hosts[host] ?? []) + fresh.map(\.id)).sorted().suffix(500))
        try validate()
        return fresh
    }
    public mutating func merge(_ other: Self) throws {
        try other.validate()
        for (host, ids) in other.hosts {
            hosts[host] = Array(Set((hosts[host] ?? []) + ids).sorted().suffix(500))
        }
        try validate()
    }
}
