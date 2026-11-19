import Foundation

/// Background advertisements are coalesced by iOS, so missing packets cannot
/// prove a radio exit. Require three actually received, authenticated far RSSI
/// samples, at least five seconds apart, with five dBm of hysteresis instead.
/// The caller verifies every advertisement before supplying its measurement.
public struct BLEBackgroundRearm {
    private struct Outside { var first: TimeInterval; var last: TimeInterval; var count: Int }
    private var outside: [String:Outside] = [:]
    public init() {}
    public mutating func receive(key: String, rssi: Int, radiusM: Int, now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, (-127...20).contains(rssi) else { return false }
        guard rssi < BLEProximityRuntime.threshold(radiusM)-5 else { outside.removeValue(forKey:key); return false }
        guard var prior = outside[key], now >= prior.last, now-prior.last <= 60 else {
            outside[key] = Outside(first:now,last:now,count:1); return false
        }
        guard now-prior.last >= 5 else { return false }
        prior.last = now; prior.count += 1; outside[key] = prior
        guard prior.count >= 3, now-prior.first >= 10 else { return false }
        outside.removeValue(forKey:key); return true
    }
    public mutating func reset() { outside.removeAll() }
}
