import Foundation

public enum AutomationRuleLevel: String, Codable, CaseIterable { case own, suggest, force }

public struct AutomationGeoPoint: Codable, Equatable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer(); lat = try c.decode(Double.self); lon = try c.decode(Double.self)
        guard c.isAtEnd else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer(); try c.encode(lat); try c.encode(lon)
    }
    public var valid: Bool { lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon) }
}

public struct AutomationTimeEntry: Codable, Equatable {
    public var weekdays: Set<Int>
    public var fromMin: Int
    public var toMin: Int
    public init(weekdays: Set<Int> = [], fromMin: Int = 0, toMin: Int = 1439) {
        self.weekdays = weekdays; self.fromMin = fromMin; self.toMin = toMin
    }
    enum CodingKeys: String, CodingKey { case weekdays = "wd", fromMin = "f", toMin = "t" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? []
        fromMin = try c.decodeIfPresent(Int.self, forKey: .fromMin) ?? 0
        toMin = try c.decodeIfPresent(Int.self, forKey: .toMin) ?? 1439
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weekdays.sorted(), forKey: .weekdays)
        try c.encode(fromMin, forKey: .fromMin); try c.encode(toMin, forKey: .toMin)
    }
}

private struct AutomationWireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// Preserve future owner fields while editing one known rule. Integer values do
// not pass through Double, which would lose precision in a future identifier.
private enum AutomationJSON: Codable, Equatable {
    case null, bool(Bool), integer(Int64), unsigned(UInt64), number(Double), string(String)
    case array([Self]), object([String: Self])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Exact Prefs.GuestTemplate wire names; storage scope belongs to the caller:
/// owner's object, owner's issued (key, object), or received (key, object).
public struct AutomationTemplate: Codable, Equatable {
    public var combineMode: String = "any"
    public var combineEnabled: Bool = false
    public var combineLevel: AutomationRuleLevel = .suggest
    public var geoEnabled: Bool = false
    public var geoLevel: AutomationRuleLevel = .suggest
    public var geoLat: Double? = nil
    public var geoLon: Double? = nil
    public var radiusM: Int? = nil
    public var geoMode: String = "zone"
    public var corridors: [[AutomationGeoPoint]] = []
    public var gateRadiusM: Int? = nil
    public var geoFromOwner: Bool = false
    public var ownerRadiusMaxM: Int? = nil
    public var wifiEnabled: Bool = false
    public var wifiLevel: AutomationRuleLevel = .suggest
    public var wifiMode: String = "connect"
    public var wifiConnectBssid: String = ""
    public var wifiConnectSsid: String = ""
    public var wifiBssids: [String] = []
    public var wifiSsids: [String] = []
    public var wifiMinMatch: Int = 2
    public var ownerMinMatch: Int? = nil
    public var timeEnabled: Bool = false
    public var timeLevel: AutomationRuleLevel = .suggest
    public var timeEntries: [AutomationTimeEntry] = []
    public var authEnabled: Bool = false
    public var authLevel: AutomationRuleLevel = .suggest
    public var authMode: String? = nil
    public var confirmEnabled: Bool = false
    public var confirmLevel: AutomationRuleLevel = .suggest
    public var requireConfirmation: Bool? = nil
    public var bleEnabled: Bool = false
    public var bleLevel: AutomationRuleLevel = .suggest
    public var bleRadiusM: Int = 3
    public var ownerBleRadiusMaxM: Int? = nil
    private var unknown: [String: AutomationJSON] = [:]
    public init() {}
    public init(data: Data?) throws {
        guard let data else { self.init(); return }
        guard data.count <= 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
        self = try JSONDecoder().decode(Self.self, from: data)
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
        return bytes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AutomationWireKey.self)
        combineMode = try c.decodeIfPresent(String.self, forKey: .init("mode")) ?? "any"
        combineEnabled = try c.decodeIfPresent(Bool.self, forKey: .init("mode_on")) ?? false
        combineLevel = try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init("mode_l")) ?? .suggest
        geoEnabled = try c.decodeIfPresent(Bool.self, forKey: .init("geo_on")) ?? false
        geoLevel = try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init("geo_l")) ?? .suggest
        geoLat = try c.decodeIfPresent(Double.self, forKey: .init("lat"))
        geoLon = try c.decodeIfPresent(Double.self, forKey: .init("lon"))
        radiusM = try c.decodeIfPresent(Int.self, forKey: .init("rad"))
        geoMode = try c.decodeIfPresent(String.self, forKey: .init("geo_mode")) ?? "zone"
        corridors = try c.decodeIfPresent([[AutomationGeoPoint]].self, forKey: .init("corridors")) ?? []
        gateRadiusM = try c.decodeIfPresent(Int.self, forKey: .init("gate_rad"))
        geoFromOwner = try c.decodeIfPresent(Bool.self, forKey: .init("geo_own")) ?? false
        ownerRadiusMaxM = try c.decodeIfPresent(Int.self, forKey: .init("rad_o"))
        wifiEnabled = try c.decodeIfPresent(Bool.self, forKey: .init("wifi_on")) ?? false
        wifiLevel = try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init("wifi_l")) ?? .suggest
        wifiMode = try c.decodeIfPresent(String.self, forKey: .init("wifi_mode")) ?? "connect"
        wifiConnectBssid = try c.decodeIfPresent(String.self, forKey: .init("wifi_cb")) ?? ""
        wifiConnectSsid = try c.decodeIfPresent(String.self, forKey: .init("wifi_cs")) ?? ""
        wifiBssids = try c.decodeIfPresent([String].self, forKey: .init("wifi_bs")) ?? []
        wifiSsids = try c.decodeIfPresent([String].self, forKey: .init("wifi_ss")) ?? []
        wifiMinMatch = try c.decodeIfPresent(Int.self, forKey: .init("wifi_mm")) ?? 2
        ownerMinMatch = try c.decodeIfPresent(Int.self, forKey: .init("wifi_mm_o"))
        timeEnabled = try c.decodeIfPresent(Bool.self, forKey: .init("time_on")) ?? false
        timeLevel = try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init("time_l")) ?? .suggest
        timeEntries = try c.decodeIfPresent([AutomationTimeEntry].self, forKey: .init("time_e")) ?? []
        authEnabled = try c.decodeIfPresent(Bool.self, forKey: .init("auth_on")) ?? false
        authLevel = try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init("auth_l")) ?? .suggest
        authMode = try c.decodeIfPresent(String.self, forKey: .init("auth"))
        confirmEnabled = try c.decodeIfPresent(Bool.self, forKey: .init("confirm_on")) ?? false
        confirmLevel = try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init("confirm_l")) ?? .suggest
        requireConfirmation = try c.decodeIfPresent(Bool.self, forKey: .init("confirm"))
        bleEnabled = try c.decodeIfPresent(Bool.self, forKey: .init("ble_on")) ?? false
        bleLevel = try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init("ble_l")) ?? .suggest
        bleRadiusM = try c.decodeIfPresent(Int.self, forKey: .init("ble_rad")) ?? 3
        ownerBleRadiusMaxM = try c.decodeIfPresent(Int.self, forKey: .init("ble_rad_o"))
        if !c.contains(.init("geo_l")) {
            let old = try ["point_l", "rad_l"].compactMap { try c.decodeIfPresent(AutomationRuleLevel.self, forKey: .init($0)) }
            let ranks = AutomationRuleLevel.allCases
            geoLevel = old.max { ranks.firstIndex(of: $0)! < ranks.firstIndex(of: $1)! } ?? .suggest
        }
        if authMode == "" { authMode = nil }
        let known = Set(["mode","mode_on","mode_l","geo_on","geo_l","lat","lon","rad","geo_mode","corridors","gate_rad","geo_own","rad_o","wifi_on","wifi_l","wifi_mode","wifi_cb","wifi_cs","wifi_bs","wifi_ss","wifi_mm","wifi_mm_o","time_on","time_l","time_e","auth_on","auth_l","auth","confirm_on","confirm_l","confirm","ble_on","ble_l","ble_rad","ble_rad_o"])
        for key in c.allKeys where !known.contains(key.stringValue) {
            unknown[key.stringValue] = try c.decode(AutomationJSON.self, forKey: key)
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: AutomationWireKey.self)
        for (key, value) in unknown { try c.encode(value, forKey: .init(key)) }
        try c.encode(combineMode, forKey: .init("mode"))
        try c.encode(combineEnabled, forKey: .init("mode_on"))
        try c.encode(combineLevel, forKey: .init("mode_l"))
        try c.encode(geoEnabled, forKey: .init("geo_on"))
        try c.encode(geoLevel, forKey: .init("geo_l"))
        try c.encodeIfPresent(geoLat, forKey: .init("lat"))
        try c.encodeIfPresent(geoLon, forKey: .init("lon"))
        try c.encodeIfPresent(radiusM, forKey: .init("rad"))
        try c.encode(geoMode, forKey: .init("geo_mode"))
        try c.encode(corridors, forKey: .init("corridors"))
        try c.encodeIfPresent(gateRadiusM, forKey: .init("gate_rad"))
        try c.encode(geoFromOwner, forKey: .init("geo_own"))
        try c.encodeIfPresent(ownerRadiusMaxM, forKey: .init("rad_o"))
        try c.encode(wifiEnabled, forKey: .init("wifi_on"))
        try c.encode(wifiLevel, forKey: .init("wifi_l"))
        try c.encode(wifiMode, forKey: .init("wifi_mode"))
        try c.encode(wifiConnectBssid, forKey: .init("wifi_cb"))
        try c.encode(wifiConnectSsid, forKey: .init("wifi_cs"))
        try c.encode(wifiBssids, forKey: .init("wifi_bs"))
        try c.encode(wifiSsids, forKey: .init("wifi_ss"))
        try c.encode(wifiMinMatch, forKey: .init("wifi_mm"))
        try c.encodeIfPresent(ownerMinMatch, forKey: .init("wifi_mm_o"))
        try c.encode(timeEnabled, forKey: .init("time_on"))
        try c.encode(timeLevel, forKey: .init("time_l"))
        try c.encode(timeEntries, forKey: .init("time_e"))
        try c.encode(authEnabled, forKey: .init("auth_on"))
        try c.encode(authLevel, forKey: .init("auth_l"))
        try c.encodeIfPresent(authMode, forKey: .init("auth"))
        try c.encode(confirmEnabled, forKey: .init("confirm_on"))
        try c.encode(confirmLevel, forKey: .init("confirm_l"))
        try c.encodeIfPresent(requireConfirmation, forKey: .init("confirm"))
        try c.encode(bleEnabled, forKey: .init("ble_on"))
        try c.encode(bleLevel, forKey: .init("ble_l"))
        try c.encode(bleRadiusM, forKey: .init("ble_rad"))
        try c.encodeIfPresent(ownerBleRadiusMaxM, forKey: .init("ble_rad_o"))
    }
    public func validate() throws {
        guard ["any", "all"].contains(combineMode), ["zone", "route"].contains(geoMode),
              ["connect", "fingerprint"].contains(wifiMode),
              authMode.map({ ["pin", "biometric", "either"].contains($0) }) ?? true,
              (geoLat == nil) == (geoLon == nil),
              geoLat.map({ $0.isFinite && (-90...90).contains($0) }) ?? true,
              geoLon.map({ $0.isFinite && (-180...180).contains($0) }) ?? true,
              radiusM.map({ (1...100_000).contains($0) }) ?? true,
              gateRadiusM.map({ (1...100_000).contains($0) }) ?? true,
              ownerRadiusMaxM.map({ (1...100_000).contains($0) }) ?? true,
              corridors.count <= 6, corridors.reduce(0, { $0 + $1.count }) <= 16384,
              corridors.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.valid) }),
              wifiBssids.count <= 2048, wifiSsids.count <= 2048,
              (1...2048).contains(wifiMinMatch), ownerMinMatch.map({ (1...2048).contains($0) }) ?? true,
              wifiConnectBssid.utf8.count <= 256, wifiConnectSsid.utf8.count <= 256,
              wifiBssids.allSatisfy({ $0.utf8.count <= 256 }), wifiSsids.allSatisfy({ $0.utf8.count <= 256 }),
              timeEntries.count <= 1000,
              timeEntries.allSatisfy({ $0.weekdays.isSubset(of: Set(1...7)) && (0...1439).contains($0.fromMin) && (0...1439).contains($0.toMin) }),
              (0...30).contains(bleRadiusM), ownerBleRadiusMaxM.map({ (1...30).contains($0) }) ?? true else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
    }

    public func resolvingGeo(from object: Self) -> Self {
        guard geoFromOwner else { return self }
        var copy = self
        copy.geoLat = object.geoLat; copy.geoLon = object.geoLon; copy.radiusM = object.radiusM
        copy.geoMode = object.geoMode; copy.corridors = object.corridors; copy.gateRadiusM = object.gateRadiusM
        copy.geoFromOwner = false
        return copy
    }

    /// Vault.mergeIncomingTemplate: changed local choices survive suggest/own;
    /// force always takes owner values with the documented directional bounds.
    public static func mergingIncoming(previous guest: Self?, owner: Self, previousOwner old: Self?) -> Self {
        guard let guest else {
            var first = owner; first.ownerRadiusMaxM = owner.radiusM
            first.ownerMinMatch = owner.wifiMinMatch; first.geoFromOwner = false
            return first
        }
        func pick<T: Equatable>(_ level: AutomationRuleLevel, _ o: T, _ g: T, _ po: T?, _ first: T) -> T {
            if level == .force { return o }
            if old != nil { return g == po ? o : g }
            return first
        }
        func on(_ level: AutomationRuleLevel, _ o: Bool, _ g: Bool, _ po: Bool?) -> Bool { pick(level, o, g, po, o) }
        struct Geometry: Equatable {
            let lat: Double?; let lon: Double?; let mode: String; let paths: [[AutomationGeoPoint]]; let gate: Int?
            init(_ t: AutomationTemplate) { lat=t.geoLat; lon=t.geoLon; mode=t.geoMode; paths=t.corridors; gate=t.gateRadiusM }
        }
        let og = Geometry(owner), gg = Geometry(guest)
        let firstGeo = gg.lat == nil || gg.lon == nil || (gg.paths.isEmpty && !og.paths.isEmpty) ? og : gg
        let geo = pick(owner.geoLevel, og, gg, old.map(Geometry.init), firstGeo)
        var result = owner
        result.combineMode = pick(owner.combineLevel, owner.combineMode, guest.combineMode, old?.combineMode, owner.combineMode)
        result.geoEnabled = on(owner.geoLevel, owner.geoEnabled, guest.geoEnabled, old?.geoEnabled)
        result.geoLat = geo.lat; result.geoLon = geo.lon; result.geoMode = geo.mode; result.corridors = geo.paths; result.gateRadiusM = geo.gate
        if owner.geoLevel == .force, let maximum = owner.radiusM { result.radiusM = min(guest.radiusM ?? maximum, maximum) }
        else { result.radiusM = pick(owner.geoLevel, owner.radiusM, guest.radiusM, old.map(\.radiusM), guest.radiusM ?? owner.radiusM) }
        result.ownerRadiusMaxM = owner.radiusM; result.geoFromOwner = false
        result.wifiEnabled = on(owner.wifiLevel, owner.wifiEnabled, guest.wifiEnabled, old?.wifiEnabled)
        let oWifi = [owner.wifiMode, owner.wifiConnectBssid, owner.wifiConnectSsid]
        let gWifi = [guest.wifiMode, guest.wifiConnectBssid, guest.wifiConnectSsid]
        let wifi = pick(owner.wifiLevel, oWifi, gWifi, old.map { [$0.wifiMode,$0.wifiConnectBssid,$0.wifiConnectSsid] }, guest.wifiConnectBssid.isEmpty ? oWifi : gWifi)
        result.wifiMode=wifi[0]; result.wifiConnectBssid=wifi[1]; result.wifiConnectSsid=wifi[2]
        result.wifiMinMatch = owner.wifiLevel == .force ? max(guest.wifiMinMatch, owner.wifiMinMatch) : pick(.suggest, owner.wifiMinMatch, guest.wifiMinMatch, old?.wifiMinMatch, guest.wifiMinMatch)
        result.ownerMinMatch = owner.wifiMinMatch
        result.timeEnabled = on(owner.timeLevel, owner.timeEnabled, guest.timeEnabled, old?.timeEnabled)
        result.timeEntries = pick(owner.timeLevel, owner.timeEntries, guest.timeEntries, old?.timeEntries, guest.timeEntries.isEmpty ? owner.timeEntries : guest.timeEntries)
        result.authEnabled = on(owner.authLevel, owner.authEnabled, guest.authEnabled, old?.authEnabled)
        result.authMode = pick(owner.authLevel, owner.authMode, guest.authMode, old.map(\.authMode), guest.authMode ?? owner.authMode)
        result.confirmEnabled = on(owner.confirmLevel, owner.confirmEnabled, guest.confirmEnabled, old?.confirmEnabled)
        result.requireConfirmation = pick(owner.confirmLevel, owner.requireConfirmation, guest.requireConfirmation, old.map(\.requireConfirmation), guest.requireConfirmation ?? owner.requireConfirmation)
        result.bleEnabled = on(owner.bleLevel, owner.bleEnabled, guest.bleEnabled, old?.bleEnabled)
        result.bleRadiusM = pick(owner.bleLevel, owner.bleRadiusM, guest.bleRadiusM, old?.bleRadiusM, guest.bleRadiusM)
        if let maximum = owner.ownerBleRadiusMaxM { result.bleRadiusM = min(result.bleRadiusM, maximum) }
        return result
    }
}
