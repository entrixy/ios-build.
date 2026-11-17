import Foundation

/// Android Prefs settings scoped to one issued key and one server object.
public struct OwnerCallPreference: Codable, Equatable {
    public var reaction = "auto"
    public var serveDuringCall = false
    public init() {}
    public func validate() throws {
        guard ["auto", "confirm", "notify", "off"].contains(reaction) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}

public enum BLETokenLifetime {
    public static let levels: [UInt32] = [3600,7200,14400,28800,43200,86400,172800,259200,604800,1209600,2592000]
    public static let defaultValue: UInt32 = 86400
}

/// A form's pending choices. No signing identity or network request is created
/// merely by opening a nested settings sheet for a new guest.
public struct OwnerKeyConfiguration: Equatable {
    public var automation: [String: Data] = [:]
    public var streams: [Int]?
    public var bleLifetimes: [String: UInt32] = [:]
    public var calls: [String: OwnerCallPreference] = [:]
    public init() {}
    public func validate(numberIDs: [Int]) throws {
        let ids = Set(numberIDs.map(String.init))
        guard automation.count <= 1000, bleLifetimes.count <= 1000, calls.count <= 1000,
              Set(automation.keys).isSubset(of: ids), Set(bleLifetimes.keys).isSubset(of: ids), Set(calls.keys).isSubset(of: ids),
              Set(streams ?? []).isSubset(of: Set(numberIDs)), Set(streams ?? []).count == (streams ?? []).count,
              bleLifetimes.values.allSatisfy({ BLETokenLifetime.levels.contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        for data in automation.values { _ = try AutomationTemplate(data: data) }
        for value in calls.values { try value.validate() }
    }
}

public extension OwnerIssuedKey {
    var configuration: OwnerKeyConfiguration {
        var result = OwnerKeyConfiguration()
        result.automation = automationTemplates ?? [:]; result.streams = streamAllowed
        result.bleLifetimes = bleTokenLifetimes ?? [:]; result.calls = callPreferences ?? [:]
        return result
    }
    mutating func configureLifetime(numberID: Int, seconds: UInt32) throws {
        guard numberIDs.contains(numberID), BLETokenLifetime.levels.contains(seconds), state == .active || state == .paused,
              pending != .keyRevoke else { throw GuestCrypto.Failure.invalidEnvelope }
        var values = bleTokenLifetimes ?? [:]; values[String(numberID)] = seconds; bleTokenLifetimes = values
        // This changes the NEXT renewal, not an already-issued token's expiry.
    }
    mutating func configureCall(numberID: Int, preference: OwnerCallPreference) throws {
        guard numberIDs.contains(numberID), state == .active || state == .paused, pending != .keyRevoke else { throw GuestCrypto.Failure.invalidEnvelope }
        try preference.validate()
        var values = callPreferences ?? [:]; values[String(numberID)] = preference; callPreferences = values
    }
}
