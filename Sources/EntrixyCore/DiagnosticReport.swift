import Foundation
import CoreFoundation

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case connection_failed, storage_error, network_policy_blocked, network_policy_unsupported
        case paused, awaiting_owner, server_error, rate_limited, too_many_requests, invalid_response
        case disabled, expired, revoked, auth, evicted, bad_key, not_found
    }
    public let code: Code
    public let date: Date
    public init(code: Code,date: Date = Date()) { self.code = code; self.date = date }
    public func validate() throws {
        guard date.timeIntervalSince1970.isFinite,date.timeIntervalSince1970 > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}

/// Only technical counts and fixed status codes, never access material, names,
/// server addresses, coordinates, Wi-Fi identifiers or the user's action journal.
public struct DiagnosticFacts: Codable, Equatable, Sendable {
    public let owners: Int
    public let guests: Int
    public let objects: Int
    public let pending: Int
    public let connected: Int
    public let storageReady: Bool
    public let privacyBlocked: Bool
    public init(owners: Int,guests: Int,objects: Int,pending: Int,connected: Int,storageReady: Bool,privacyBlocked: Bool) {
        self.owners = owners; self.guests = guests; self.objects = objects; self.pending = pending
        self.connected = connected; self.storageReady = storageReady; self.privacyBlocked = privacyBlocked
    }
    public func validate() throws {
        guard [owners,guests,objects,pending,connected].allSatisfy({ (0...1_000_000).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}

/// MetricKit call stacks are rebuilt from an allowlist. Raw diagnostic strings,
/// paths, exception messages and arbitrary JSON fields cannot enter a report.
public struct DiagnosticCrash: Codable, Equatable, Sendable {
    public let recordedAt: Date
    public let stack: Data
    public init(recordedAt: Date,stack: Data) throws {
        guard recordedAt.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince1970 > 0,
              stack.count <= 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
        var remaining = 4096
        func clean(_ raw: Any,depth: Int) throws -> Any {
            guard depth <= 64, remaining > 0 else { throw GuestCrypto.Failure.invalidEnvelope }
            remaining -= 1
            if let list = raw as? [Any] {
                guard list.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
                return try list.map { try clean($0,depth:depth+1) }
            }
            guard let row = raw as? [String:Any] else { throw GuestCrypto.Failure.invalidEnvelope }
            var result: [String:Any] = [:]
            for field in ["callStacks","callStackRootFrames","subFrames"] where row[field] != nil {
                guard let list = row[field] as? [Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                result[field] = try clean(list,depth:depth+1)
            }
            for field in ["threadAttributed","callStackPerThread"] {
                if let value = row[field] {
                    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw GuestCrypto.Failure.invalidEnvelope }
                    result[field] = n.boolValue
                }
            }
            for field in ["address","offsetIntoBinaryTextSegment","sampleCount"] {
                if let value = row[field] {
                    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                          let value = UInt64(n.stringValue), n == NSNumber(value:value) else { throw GuestCrypto.Failure.invalidEnvelope }
                    result[field] = value
                }
            }
            if let value = row["binaryUUID"] as? String, let uuid = UUID(uuidString:value) { result["binaryUUID"] = uuid.uuidString }
            if let value = row["binaryName"] as? String, value.utf8.count <= 128,
               value.range(of:"^[A-Za-z0-9_.+-]+$",options:.regularExpression) != nil {
                result["binaryName"] = value
            }
            return result
        }
        guard let root = try JSONSerialization.jsonObject(with:stack) as? [String:Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        let source = root["callStackTree"] as? [String:Any] ?? root
        guard source["callStacks"] is [Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        self.stack = try JSONSerialization.data(withJSONObject:clean(source,depth:0),options:.sortedKeys)
        self.recordedAt = recordedAt
    }
    public func validate() throws {
        let normalized = try Self(recordedAt:recordedAt,stack:stack)
        guard normalized.stack == stack else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}

public struct DiagnosticReport: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case manual = "ios-manual", crash = "ios-crash" }
    public let id: String
    public let kind: Kind
    public let created: Date
    public let appVersion: String
    public let build: String
    public let osVersion: String
    public let facts: DiagnosticFacts
    public let crashes: [DiagnosticCrash]
    public let events: [DiagnosticEvent]
    public init(kind: Kind,appVersion: String,build: String,osVersion: String,facts: DiagnosticFacts,crashes: [DiagnosticCrash] = [],events: [DiagnosticEvent] = [],created: Date = Date()) throws {
        id = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        self.kind = kind; self.created = created; self.appVersion = appVersion; self.build = build
        self.osVersion = osVersion; self.facts = facts; self.crashes = crashes; self.events = events
        try validate()
    }
    public func validate() throws {
        guard id.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil,
              created.timeIntervalSince1970.isFinite, created.timeIntervalSince1970 > 0,
              [appVersion,build,osVersion].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 40 && $0.range(of:"^[A-Za-z0-9._+() -]+$",options:.regularExpression) != nil }),
              crashes.count <= 8, events.count <= 100, kind != .crash || !crashes.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        try facts.validate(); try crashes.forEach { try $0.validate() }
        try events.forEach { try $0.validate() }
        guard try JSONEncoder().encode(self).count <= 524_288 else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public func body() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let formatter = ISO8601DateFormatter()
        var contents: [String:Any] = ["platform":"iOS","kind":kind.rawValue,
            "crashes":try crashes.map { ["recordedAt":formatter.string(from:$0.recordedAt),"stack":try JSONSerialization.jsonObject(with:$0.stack)] as [String:Any] }]
        if kind == .manual {
            contents["facts"] = try JSONSerialization.jsonObject(with:encoder.encode(facts))
            contents["events"] = try JSONSerialization.jsonObject(with:encoder.encode(events))
            contents["osVersion"] = osVersion; contents["build"] = build
        }
        // Keep the random request ID outside the deduplicated log. The server
        // can normalize visible timestamps/addresses in the structured stack.
        let log = String(decoding:try JSONSerialization.data(withJSONObject:contents,options:.sortedKeys),as:UTF8.self)
        return try JSONSerialization.data(withJSONObject:["log":log,"version":kind.rawValue,
            "device":"Apple iOS","app_version":appVersion,"iid":id],options:.sortedKeys)
    }
}
