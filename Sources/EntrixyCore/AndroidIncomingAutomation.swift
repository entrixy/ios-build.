import Foundation

/// Android keeps the user's effective template and the previous owner template
/// separately. They are only a migration seed; a fresh authenticated bundle must
/// supply current owner rules before the corresponding object becomes usable.
public struct AndroidIncomingAutomation: Codable, Equatable {
    public let local: AutomationTemplate
    public let previousOwner: AutomationTemplate?
    public init(local: AutomationTemplate,previousOwner: AutomationTemplate?) throws {
        self.local = local; self.previousOwner = previousOwner; try validate()
    }
    public func validate() throws { try local.validate(); try previousOwner?.validate() }
    public func receiving(_ fresh: AutomationTemplate) throws -> IncomingAutomationConfiguration {
        try validate(); try fresh.validate()
        var result = IncomingAutomationConfiguration(owner:fresh)
        result.effective = AutomationTemplate.mergingIncoming(previous:local,owner:fresh,previousOwner:previousOwner)
        try result.effective.validate(); return result
    }
    public static func validate(_ rules: [String:Self]) throws {
        guard rules.count <= 1000, rules.keys.allSatisfy({ key in Int(key).map { $0 > 0 && String($0) == key } == true }) else { throw GuestCrypto.Failure.invalidEnvelope }
        for rule in rules.values { try rule.validate() }
    }
}

public extension AndroidBackupDocument {
    func incomingAutomation(localID: Int) throws -> [String:AndroidIncomingAutomation] {
        guard try guests().contains(where:{ $0.localID == localID }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let prefix = "e2ee_in_tpl_\(localID)_"
        var result: [String:AndroidIncomingAutomation] = [:]
        for key in entries.keys where key.hasPrefix(prefix) {
            let number = String(key.dropFirst(prefix.count))
            guard let raw = try string(key) else { throw GuestCrypto.Failure.invalidEnvelope }
            let previous = try string("e2ee_in_tplo_\(localID)_" + number).map { try AutomationTemplate(data:Data($0.utf8)) }
            result[number] = try AndroidIncomingAutomation(local:AutomationTemplate(data:Data(raw.utf8)),previousOwner:previous)
        }
        try AndroidIncomingAutomation.validate(result); return result
    }
}
