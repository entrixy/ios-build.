import Foundation

/// Android GeoTracker's poor-fix warning: four minutes without <=80m accuracy
/// while the provider is still delivering fixes within the last90seconds.
/// This diagnostic never grants action authority or calls a transport.
public struct LocationQualityMonitor {
    private var started: TimeInterval?
    private var lastFix: TimeInterval?
    private var lastAccurate: TimeInterval?
    public init() {}
    public mutating func reset(at date: Date) { started = date.timeIntervalSince1970; lastFix = nil; lastAccurate = nil }
    public mutating func receive(at date: Date, accuracy: Double) {
        let now = date.timeIntervalSince1970
        guard now.isFinite, accuracy.isFinite, accuracy >= 0, lastFix.map({ now >= $0 }) ?? true else { return }
        if started == nil { started = now }
        lastFix = now
        if accuracy <= 80 { lastAccurate = now }
    }
    public func unreliable(at date: Date) -> Bool {
        let now = date.timeIntervalSince1970
        guard let lastFix, let beginning = lastAccurate ?? started,
              now >= lastFix, now-lastFix < 90 else { return false }
        return now-beginning > 240
    }
}
