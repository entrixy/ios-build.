import Foundation

/// The same calculation is used for UI readiness and the trigger coordinator.
/// Values describe observations, never permission to bypass an action policy.
public struct AutomationObservations: Equatable {
    public var geoMatched = false
    public var lastOutsideOrange: TimeInterval?
    public var sessionStarted: TimeInterval
    public var wifiMatches: Int?
    public var wifiRequired: Int?
    public var bleReady: Bool?
    public init(sessionStarted: TimeInterval) { self.sessionStarted = sessionStarted }
}

public enum AutomationEvaluation {
    public static func outsideEntry(_ observations: AutomationObservations, now: TimeInterval) -> Bool {
        guard let outside = observations.lastOutsideOrange else { return false }
        return outside > observations.sessionStarted && now >= outside && now - outside < 300
    }

    /// weekday follows Calendar: Sunday=1, Monday=2. An overnight window's
    /// morning belongs to the previous day, including Sunday/Monday rollover.
    public static func secondsLeftInWindow(_ entry: AutomationTimeEntry, weekday: Int, seconds: Int) -> Int? {
        guard (1...7).contains(weekday), (0..<86400).contains(seconds) else { return nil }
        let from = entry.fromMin * 60, to = entry.toMin * 60
        func day(_ value: Int) -> Bool { entry.weekdays.isEmpty || entry.weekdays.contains(value) }
        guard from != to else { return nil }
        if to > from { return day(weekday) && seconds >= from && seconds < to ? to - seconds : nil }
        if day(weekday) && seconds >= from { return 86400 - seconds + to }
        let previous = weekday == 1 ? 7 : weekday - 1
        return day(previous) && seconds < to ? to - seconds : nil
    }

    public static func timeReady(_ template: AutomationTemplate, date: Date, calendar: Calendar = .current) -> Bool {
        guard template.timeEnabled, !template.timeEntries.isEmpty else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return false }
        let seconds = hour * 3600 + minute * 60 + second
        return template.timeEntries.contains { entry in
            if template.combineMode != "all" || entry.fromMin == entry.toMin {
                return (entry.weekdays.isEmpty || entry.weekdays.contains(weekday)) &&
                    seconds >= entry.fromMin * 60 && seconds < entry.fromMin * 60 + 180
            }
            return secondsLeftInWindow(entry, weekday: weekday, seconds: seconds) != nil
        }
    }

    public static func channels(_ template: AutomationTemplate, observations: AutomationObservations,
                                date: Date, calendar: Calendar = .current) -> [String: Bool] {
        var values: [String: Bool] = [:]
        if template.geoEnabled && template.geoMode != "route" {
            values["geo"] = observations.geoMatched && outsideEntry(observations, now: date.timeIntervalSince1970)
        }
        if template.wifiEnabled {
            if let count = observations.wifiMatches, let required = observations.wifiRequired, required > 0 {
                values["wifi"] = count >= required
            } else { values["wifi"] = false }
        }
        if template.timeEnabled && !template.timeEntries.isEmpty { values["time"] = timeReady(template, date: date, calendar: calendar) }
        if template.bleEnabled, let ble = observations.bleReady { values["ble"] = ble }
        return values
    }

    public static func matched(_ template: AutomationTemplate, observations: AutomationObservations,
                               date: Date, calendar: Calendar = .current) -> Bool {
        let values = Array(channels(template, observations: observations, date: date, calendar: calendar).values)
        guard !values.isEmpty else { return false }
        return template.combineMode == "all" ? values.allSatisfy { $0 } : values.contains(true)
    }
}

/// Persistent local/owner snapshots keep incoming overrides scoped to one key
/// and object. The key's next authenticated bundle is merged, not blindly copied.
public struct IncomingAutomationConfiguration: Codable, Equatable {
    public var owner: AutomationTemplate
    public var effective: AutomationTemplate
    public init(owner: AutomationTemplate) {
        self.owner = owner
        effective = AutomationTemplate.mergingIncoming(previous: nil, owner: owner, previousOwner: nil)
    }
    public mutating func receive(_ fresh: AutomationTemplate) {
        effective = AutomationTemplate.mergingIncoming(previous: effective, owner: fresh, previousOwner: owner)
        owner = fresh
    }
    public mutating func edit(_ candidate: AutomationTemplate) throws {
        try candidate.validate()
        var checked = AutomationTemplate.mergingIncoming(previous: candidate, owner: owner, previousOwner: owner)
        if owner.combineLevel == .force && owner.combineMode == "all" {
            checked.geoEnabled = owner.geoEnabled; checked.wifiEnabled = owner.wifiEnabled
            checked.timeEnabled = owner.timeEnabled; checked.bleEnabled = owner.bleEnabled
        }
        try checked.validate(); effective = checked
    }
}
