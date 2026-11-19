import Foundation

/// Android GeoTracker's poor-fix warning: four minutes without <=80m accuracy
/// while the provider is still delivering fixes within the last90seconds.
/// Also detects a <=40m frozen anchor for four minutes with independently
/// measured motion in the last minute. Without motion, standing still is valid.
/// This diagnostic never grants action authority or calls a transport.
public struct LocationQualityMonitor {
    private var started: TimeInterval?
    private var lastFix: TimeInterval?
    private var lastAccurate: TimeInterval?
    private var positionAnchor: AutomationGeoPoint?
    private var lastPositionChange: TimeInterval?
    private var lastMoving: TimeInterval?
    public init() {}
    public mutating func reset(at date: Date) { started = date.timeIntervalSince1970; lastFix = nil; lastAccurate = nil; positionAnchor = nil; lastPositionChange = nil; lastMoving = nil }
    public mutating func receive(at date: Date, accuracy: Double, position: AutomationGeoPoint? = nil) {
        let now = date.timeIntervalSince1970
        guard now.isFinite, accuracy.isFinite, accuracy >= 0, lastFix.map({ now >= $0 }) ?? true else { return }
        if started == nil { started = now }
        lastFix = now
        if accuracy <= 80 {
            lastAccurate = now
            if let position, position.valid,
               positionAnchor.map({ GeoRouteGeometry.distance($0,position) >= 40 }) ?? true {
                positionAnchor = position; lastPositionChange = now
            }
        }
    }
    /// Independent gravity-free accelerometer evidence, never inferred from GPS
    /// speed or repeated coordinates. Android's linear threshold is0.2m/s².
    public mutating func receiveMotion(at date: Date, acceleration: Double) {
        let now = date.timeIntervalSince1970
        guard now.isFinite, acceleration.isFinite, acceleration >= 0.2,
              let started, now >= started, lastMoving.map({ now >= $0 }) ?? true else { return }
        lastMoving = now
    }
    public func unreliable(at date: Date) -> Bool {
        let now = date.timeIntervalSince1970
        guard let lastFix, let beginning = lastAccurate ?? started,
              now >= lastFix, now-lastFix < 90 else { return false }
        if now-beginning > 240 { return true }
        guard let lastPositionChange, let lastMoving, now >= lastMoving else { return false }
        return now-lastPositionChange > 240 && now-lastMoving < 60
    }
}
