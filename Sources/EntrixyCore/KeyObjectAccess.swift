import Foundation
import CoreFoundation

/// Matches lib/key_objects.php: only an explicit owner choice enables passing on.
public struct KeyObjectAccess: Codable, Equatable {
    public let nativeOnly: Bool
    public let depth: Int
    public let pool: Int
    public init(nativeOnly: Bool = false, depth: Int = 0, pool: Int = 3) throws {
        guard (0...5).contains(depth), (1...50).contains(pool) else { throw GuestCrypto.Failure.invalidEnvelope }
        self.nativeOnly = nativeOnly; self.depth = depth; self.pool = pool
    }
    public func validate() throws { _ = try Self(nativeOnly: nativeOnly, depth: depth, pool: pool) }
    public func json(id: Int) -> [String: Any] { ["id": id, "native_only": nativeOnly, "depth": depth, "pool": pool] }
    public static func decode(_ raw: Any?) throws -> [String: Self]? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let rows = raw as? [[String: Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
        var out: [String: Self] = [:]
        func integer(_ v: Any?) throws -> Int {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = v as? Int, n == NSNumber(value: i) else { throw GuestCrypto.Failure.invalidEnvelope }
            return i
        }
        for row in rows {
            let id = try OwnerObject.replyID(row["id"])
            guard out[String(id)] == nil, let flag = row["native_only"] as? NSNumber, flag == 0 || flag == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
            out[String(id)] = try Self(nativeOnly: flag.boolValue, depth: integer(row["depth"]), pool: integer(row["pool"]))
        }
        return out
    }
}
