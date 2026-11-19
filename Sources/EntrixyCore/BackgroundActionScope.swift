import Foundation

/// A bounded capability for ONE already configured, ungated automatic action.
/// It never grants UI/settings access and is neither Codable nor backed up.
public struct BackgroundActionScope {
    public enum Transport { case bluetooth, localWebhook }
    public let id: UUID
    public let target: ObjectReference
    public let transport: Transport
    public let deadline: TimeInterval
    private let started: TimeInterval
    private let template: Data
    public init(target: ObjectReference, transport: Transport, template: AutomationTemplate,
                uptime: TimeInterval, duration: TimeInterval, id: UUID = UUID()) throws {
        try target.validate()
        guard uptime.isFinite, uptime >= 0, duration.isFinite, duration > 0, duration <= 20,
              !template.authEnabled, !template.confirmEnabled, template.requireConfirmation != true,
              template.geoEnabled || template.wifiEnabled || template.timeEnabled || template.bleEnabled,
              transport != .bluetooth || template.bleEnabled else { throw GuestCrypto.Failure.invalidEnvelope }
        self.target = target; self.transport = transport; self.id = id
        started = uptime; deadline = uptime + duration; self.template = try template.data()
    }
    public func allows(_ target: ObjectReference, template: AutomationTemplate, uptime: TimeInterval) -> Bool {
        uptime.isFinite && uptime >= started && uptime < deadline && target == self.target && (try? template.data()) == self.template
    }
}
