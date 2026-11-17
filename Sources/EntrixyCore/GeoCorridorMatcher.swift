import Foundation

public struct AutomationLocationFix: Codable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let accuracyM: Float
    public let speedMps: Float
    public let timestampMS: Int64
    public init(latitude: Double, longitude: Double, accuracyM: Float, speedMps: Float = -1, timestampMS: Int64) {
        self.latitude = latitude; self.longitude = longitude; self.accuracyM = accuracyM
        self.speedMps = speedMps; self.timestampMS = timestampMS
    }
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && accuracyM.isFinite && accuracyM >= 0 && speedMps.isFinite && timestampMS >= 0
    }
}

/// Direct port of full Android 10.90 host/GeoCorridorMatcher.kt. Route arrival
/// requires a recent approach through the drawn polyline, not just proximity.
/// The caller consumes an approach only after an actual attempt (or a lasting
/// denial), so a temporarily busy transport does not swallow the arrival.
public struct GeoCorridorMatcher {
    private struct Near { let time: Int64; let distance: Float }
    private struct State {
        var fixes: [AutomationLocationFix] = []
        var near: [Near] = []
        var fired = false
        var consecutiveOutside = 0
        var latestTime: Int64?
    }
    private var states: [String: State] = [:]
    public init() {}
    public mutating func reset(_ key: String) { states.removeValue(forKey: key) }
    public mutating func markOpened(_ key: String) {
        var state = states[key] ?? State()
        state.fixes.removeAll(); state.fired = true; state.consecutiveOutside = 0
        states[key] = state
    }
    public func isLatched(_ key: String) -> Bool { states[key]?.fired == true }

    public mutating func update(key: String, fix: AutomationLocationFix, gate: AutomationGeoPoint,
                                corridors: [[AutomationGeoPoint]]) -> Bool {
        guard fix.isValid, gate.lat.isFinite, gate.lon.isFinite, (-90...90).contains(gate.lat),
              (-180...180).contains(gate.lon), !corridors.isEmpty,
              corridors.count <= 6, corridors.reduce(0,{ $0+$1.count }) <= 16384, corridors.allSatisfy({ $0.allSatisfy { $0.lat.isFinite && $0.lon.isFinite && (-90...90).contains($0.lat) && (-180...180).contains($0.lon) } }) else { return false }
        var state = states[key] ?? State()
        // Core Location can repeat cached fixes. They cannot count as a second
        // independent near fix or turn zero elapsed time into an approach.
        if let time = state.latestTime, fix.timestampMS <= time { return false }
        state.latestTime = fix.timestampMS
        defer { states[key] = state }
        let metersLon = 111320.0 * cos(gate.lat * .pi / 180)
        func x(_ lon: Double) -> Float { Float((lon - gate.lon) * metersLon) }
        func y(_ lat: Double) -> Float { Float((lat - gate.lat) * 111320) }
        let distance = hypot(x(fix.longitude), y(fix.latitude))
        // Android v7.96 retains poorer urban fixes for the near-window only.
        // They must never inflate the actual path/span or rearm the latch.
        if fix.accuracyM <= 120 { state.near.append(Near(time: fix.timestampMS, distance: distance)) }
        state.near.removeAll { fix.timestampMS - $0.time > 20_000 }
        guard fix.accuracyM <= 40 else { return false }
        state.fixes.append(fix)
        state.fixes.removeAll { fix.timestampMS - $0.timestampMS > 180_000 }
        if state.fixes.count > 120 { state.fixes.removeFirst(state.fixes.count - 120) }
        if state.fired {
            state.consecutiveOutside = distance > 90 ? state.consecutiveOutside + 1 : 0
            if state.consecutiveOutside >= 3 { state.fired = false; state.consecutiveOutside = 0 }
        }
        guard distance <= 55, !state.fired else { return false }
        let halfWidth = max(Float(32), 1.5 * fix.accuracyM)
        let nearReady = state.near.filter { $0.distance <= 45 }.count >= 2
        guard nearReady else { return false }
        for route in corridors where route.count >= 2 {
            let points = route.map { (x($0.lon),y($0.lat)) }
            var remaining = [Float](repeating: 0,count: points.count)
            for i in stride(from: points.count - 2, through: 0, by: -1) {
                remaining[i] = remaining[i+1] + hypot(points[i].0-points[i+1].0,points[i].1-points[i+1].1)
            }
            guard remaining[0] >= 5 else { continue }
            var projections: [(s: Float, time: Int64, speed: Float)] = []
            for sample in state.fixes {
                let px = x(sample.longitude), py = y(sample.latitude)
                var bestDistance = Float.greatestFiniteMagnitude, bestS: Float = 0
                for i in 0..<(points.count-1) {
                    let (ax,ay) = points[i], dx = points[i+1].0-ax, dy = points[i+1].1-ay
                    let length2 = dx*dx+dy*dy
                    let f: Float = length2 <= 0.000001 ? 0 : min(1,max(0,((px-ax)*dx+(py-ay)*dy)/length2))
                    let perp = hypot(px-(ax+f*dx),py-(ay+f*dy))
                    if perp < bestDistance { bestDistance = perp; bestS = remaining[i+1]+(1-f)*sqrt(length2) }
                }
                if bestDistance <= halfWidth { projections.append((bestS,sample.timestampMS,sample.speedMps)) }
            }
            guard projections.count >= 3, let newest = projections.last else { continue }
            var previous = newest.s, peak = newest.s, start = projections.count-1, count = 1
            for i in stride(from: projections.count-2, through: 0, by: -1) {
                let candidate = projections[i]
                if candidate.s < previous-20 || projections[start].time-candidate.time > 40_000 || newest.time-candidate.time > 120_000 { break }
                peak = max(peak,candidate.s); previous = candidate.s; count += 1; start = i
            }
            let span = peak-newest.s, elapsed = newest.time-projections[start].time
            guard elapsed > 0 else { continue }
            let positionalSpeed = span/(Float(elapsed)/1000)
            let dopplers = projections[start...].map(\.speed).filter { $0 >= 0 }.sorted()
            let speed = dopplers.count >= 2 ? max(positionalSpeed,dopplers[dopplers.count/2]) : positionalSpeed
            if count >= 3, span >= 25, speed >= 1.11 { return true }
        }
        return false
    }
}
