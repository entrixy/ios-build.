import Foundation
import CoreFoundation

public struct PassAllowance: Equatable {
    public let depth: Int
    public let poolLeft: Int
    public let nativeOnly: Bool
    public var canPass: Bool { depth > 0 && poolLeft > 0 && !nativeOnly }
}
public struct PassInvitation {
    public let code: String
    public let group: String
    public let status: String
    public let objects: [String: KeyObjectAccess]
}
public struct PassChild {
    public let id: Int
    public let group: String
    public let numberIDs: [Int]
    public let objects: [String: KeyObjectAccess]
    public let signPublic: String?
    public let guestPublic: String?
    public let mac: String?
    public let vouched: Bool
    public let ready: Bool
}
public struct PassSnapshot {
    public let allowance: [Int: PassAllowance]
    public let invitations: [PassInvitation]
    public let children: [PassChild]
    public let journal: [DelegatedJournalEvent]
    public static func decode(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]],
              let invites = root["invites"] as? [[String: Any]], let children = root["children"] as? [[String: Any]],
              objects.count <= 1000, invites.count <= 50, children.count <= 5000 else { throw GuestCrypto.Failure.invalidEnvelope }
        func integer(_ raw: Any?) throws -> Int {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = raw as? Int, n == NSNumber(value: i) else { throw GuestCrypto.Failure.invalidEnvelope }
            return i
        }
        func flag(_ raw: Any?) throws -> Bool {
            guard let n = raw as? NSNumber, n == 0 || n == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
            return n.boolValue
        }
        func code(_ raw: Any?) throws -> String {
            guard let value = raw as? String, DelegationLink.code(value) else { throw GuestCrypto.Failure.invalidEnvelope }; return value
        }
        func settings(_ raw: Any?) throws -> [String: KeyObjectAccess] {
            guard let rows = raw as? [[String: Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
            return try KeyObjectAccess.decode(rows.map { var row = $0; if row["native_only"] == nil { row["native_only"] = 0 }; return row }) ?? [:]
        }
        var allowed: [Int: PassAllowance] = [:]
        for row in objects {
            let id = try OwnerObject.replyID(row["id"]), depth = try integer(row["depth"]), pool = try integer(row["pool_left"])
            guard allowed[id] == nil, (0...5).contains(depth), (0...50).contains(pool) else { throw GuestCrypto.Failure.invalidEnvelope }
            allowed[id] = PassAllowance(depth: depth, poolLeft: pool, nativeOnly: try flag(row["native_only"]))
        }
        var parsedInvites: [PassInvitation] = [], seen = Set<String>()
        for row in invites {
            let part = try code(row["code"]), group = try code(row["grp"])
            guard seen.insert(part).inserted, let state = row["status"] as? String,
                  ["new", "redeemed", "expired", "cancelled"].contains(state) else { throw GuestCrypto.Failure.invalidEnvelope }
            parsedInvites.append(PassInvitation(code: part, group: group, status: state, objects: try settings(row["objects"])))
        }
        var parsedChildren: [PassChild] = [], ids = Set<Int>()
        for row in children {
            let id = try OwnerObject.replyID(row["id"]), group = try code(row["grp"])
            guard ids.insert(id).inserted, let raw = row["number_ids"] as? [Any] else { throw GuestCrypto.Failure.invalidEnvelope }
            let numbers = try raw.map { try OwnerObject.replyID($0) }
            let ble = try (row["ble_ids"] as? [Any] ?? []).map { try OwnerObject.replyID($0) }
            let access = try settings(row["objects"])
            guard Set(numbers + ble).count == numbers.count + ble.count,
                  Set(access.keys) == Set((numbers + ble).map(String.init)) else { throw GuestCrypto.Failure.invalidEnvelope }
            parsedChildren.append(PassChild(id: id, group: group, numberIDs: numbers, objects: access,
                signPublic: row["sign_pub"] as? String, guestPublic: row["guest_pub"] as? String, mac: row["pass_mac"] as? String,
                vouched: try flag(row["vouched"]), ready: try flag(row["ready"])))
        }
        var events: [DelegatedJournalEvent] = [], eventIDs = Set<Int>()
        if let raw = root["journal"] {
            guard let rows = raw as? [[String: Any]], rows.count <= 500 else { throw GuestCrypto.Failure.invalidEnvelope }
            for row in rows {
                let id = try OwnerObject.replyID(row["id"])
                let number = try OwnerObject.replyID(row["number_id"])
                let epoch = try integer(row["ts"])
                guard eventIDs.insert(id).inserted, epoch > 0, epoch <= 253402300799 else { throw GuestCrypto.Failure.invalidEnvelope }
                events.append(DelegatedJournalEvent(id: id, numberID: number, group: try code(row["grp"]), epoch: Int64(epoch)))
            }
        }
        return Self(allowance: allowed, invitations: parsedInvites, children: parsedChildren, journal: events)
    }
}
