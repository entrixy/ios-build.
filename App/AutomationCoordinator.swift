import Foundation
import Combine
import CoreLocation
import EntrixyCore

/// Observes rules separately from the command transports. Every candidate goes
/// through the same fresh policy/identity/journal checks as a manual action.
@MainActor final class AutomationCoordinator: ObservableObject {
    @Published private(set) var readiness: [ObjectReference: AutomationReadiness] = [:]
    private unowned let app: AppModel
    private var runtime = AutomationRuntime(sessionStarted: Date().timeIntervalSince1970)
    private var task: Task<Void,Never>?
    private var working = false
    private var editors = 0
    private var sending = false
    private var trackingLocation = false
    private var lastNetworkRefresh = Date.distantPast
    init(app: AppModel) { self.app = app }

    func setWorking(_ value: Bool) { working = value }
    func beginEditing() { editors += 1 }
    func endEditing() { editors = max(0,editors-1) }
    func resume() {
        guard task == nil else { return }
        app.automationSensors.onLocation = { [weak self] location in self?.receive(location) }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    func suspend() {
        task?.cancel(); task = nil
        app.automationSensors.trackLocation(enabled:false,background:false); trackingLocation = false
        readiness.removeAll()
        // A resumed session must observe a fresh outside entry. Neither stale
        // GPS/Wi-Fi nor a process restart is an automatic command retry.
        runtime = AutomationRuntime(sessionStarted:Date().timeIntervalSince1970)
    }
    func receive(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) <= 30 else { return }
        runtime.receive(AutomationLocationFix(latitude:location.coordinate.latitude,longitude:location.coordinate.longitude,
            accuracyM:Float(location.horizontalAccuracy),speedMps:Float(location.speed),
            timestampMS:Int64(max(0,location.timestamp.timeIntervalSince1970*1000))))
    }
    func inspect(_ target: ObjectReference, template: AutomationTemplate, isBLE: Bool, date: Date = Date()) -> AutomationReadiness {
        let observed = app.automationSensors.networkObservedAt
        let network = observed.map({ date.timeIntervalSince($0) >= 0 && date.timeIntervalSince($0) <= 15 }) == true
            ? app.automationSensors.network : nil
        var matches: Int?, required: Int?
        if template.wifiEnabled {
            if template.wifiMode == "connect" {
                required = 1
                if let network {
                    let configured = !template.wifiConnectBssid.isEmpty || !template.wifiConnectSsid.isEmpty
                    let same = !template.wifiConnectBssid.isEmpty ? network.bssid.caseInsensitiveCompare(template.wifiConnectBssid) == .orderedSame : network.ssid == template.wifiConnectSsid
                    matches = configured && same ? 1 : 0
                } else { matches = 0 }
            } else {
                // iOS provides the current network, not an ambient Wi-Fi scan.
                // A scan rule cannot be treated as a successful connect rule.
                matches = 0; required = max(1,template.wifiMinMatch)
            }
        }
        let result = runtime.evaluate(key:target.id,template:template,date:date,wifiMatches:matches,wifiRequired:required,
            bleReady:isBLE ? false : nil)
        return result
    }
    func consume(_ target: ObjectReference, route: Bool, date: Date = Date()) { runtime.consume(target.id,route:route,at:date) }
    private func tick() async {
        guard app.canManageGuestAccess, !Task.isCancelled else { return }
        let entries = app.controlObjects
        var contexts: [(CatalogObject,AutomationSettingsContext)] = []
        for entry in entries {
            if let context = try? app.automationContext(.object(entry.target)) { contexts.append((entry,context)) }
        }
        let needsGeo = contexts.contains { $0.1.template.geoEnabled }
        if needsGeo != trackingLocation {
            app.automationSensors.trackLocation(enabled:needsGeo,background:false); trackingLocation = needsGeo
        }
        if Date().timeIntervalSince(lastNetworkRefresh) >= 10 {
            app.automationSensors.refreshNetwork(); lastNetworkRefresh = Date()
        }
        let targets = Set(entries.map(\.target))
        runtime.retain(Set(targets.map(\.id)))
        readiness = readiness.filter { targets.contains($0.key) }
        app.automaticConsumedAt = app.automaticConsumedAt.filter { targets.contains($0.key) }
        for (entry,context) in contexts {
            let result = inspect(entry.target,template:context.template,isBLE:context.isBLE)
            if readiness[entry.target] != result { readiness[entry.target] = result }
            guard result.ready, !context.isBLE else { continue }
            // Android consumes a route seen while editing/on another tab, so
            // switching back later does not unexpectedly open the old arrival.
            if !working || editors > 0 || app.objectRemovalTarget != nil || app.objectAvatarTarget != nil {
                if result.routeMatched { consume(entry.target,route:true) }
                continue
            }
            guard !sending, !app.busy, !app.ownerBusy else { continue }
            if context.template.authEnabled || context.template.confirmEnabled || context.template.requireConfirmation == true {
                consume(entry.target,route:result.routeMatched); continue
            }
            sending = true
            await app.performAutomaticAction(entry,readiness:result)
            sending = false
        }
    }
}

extension AppModel {
    func automaticPermitValid(_ target: ObjectReference, date: Date = Date()) -> Bool {
        guard let permit = automaticPermits[target] else { return false }
        return automaticEvidenceValid(permit,target:target,date:date,maximumAge:2)
    }
    func automaticEvidenceValid(_ permit: AutomationReadiness, target: ObjectReference, date: Date = Date(), maximumAge: TimeInterval = 30) -> Bool {
        guard canManageGuestAccess, permit.ready, date >= permit.evaluatedAt,
              date.timeIntervalSince(permit.evaluatedAt) <= maximumAge,
              let context = try? automationContext(.object(target)), context.template == permit.template,
              !context.template.authEnabled, !context.template.confirmEnabled, context.template.requireConfirmation != true else { return false }
        if permit.routeMatched { return true }
        return conditionReadiness(target,date:date)?.satisfies(permit.template,at:date) == true
    }
    func noteAutomationAttempt(_ target: ObjectReference) {
        guard let context = try? automationContext(.object(target)) else { return }
        automation.consume(target,route:context.template.geoMode == "route")
    }
    func conditionReadiness(_ target: ObjectReference, date: Date = Date()) -> AutomationReadiness? {
        guard let context = try? automationContext(.object(target)) else { return nil }
        return automation.inspect(target,template:context.template,isBLE:context.isBLE,date:date)
    }
    func performAutomaticAction(_ entry: CatalogObject, readiness: AutomationReadiness) async {
        guard canManageGuestAccess, !busy, !ownerBusy,
              let context = try? automationContext(.object(entry.target)), context.template == readiness.template,
              (automaticConsumedAt[entry.target].map { readiness.evaluatedAt > $0 } ?? true),
              readiness.ready, Date().timeIntervalSince(readiness.evaluatedAt) <= 2,
              !context.template.authEnabled, !context.template.confirmEnabled, context.template.requireConfirmation != true else { return }
        automaticPermits[entry.target] = readiness
        defer { automaticPermits.removeValue(forKey:entry.target) }
        switch entry {
        case .owned(let owner,let object):
            guard object.kind != "ble", let intent = ownerActionIntent(server:owner.server,objectID:object.id,automatic:true) else { return }
            automaticConsumedAt[entry.target] = readiness.evaluatedAt
            automation.consume(entry.target,route:readiness.routeMatched)
            await execute(intent)
        case .received(let guest,let object):
            guard object.kind != "ble", let intent = actionIntent(guestID:guest.id,object:object,automatic:true) else { return }
            automaticConsumedAt[entry.target] = readiness.evaluatedAt
            automation.consume(entry.target,route:readiness.routeMatched)
            await execute(intent)
        }
    }
}
