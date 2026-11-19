import Foundation
import Combine
import CoreLocation
import CoreBluetooth
import EntrixyCore

/// Observes rules separately from the command transports. Every candidate goes
/// through the same fresh policy/identity/journal checks as a manual action.
@MainActor final class AutomationCoordinator: ObservableObject {
    @Published private(set) var readiness: [ObjectReference: AutomationReadiness] = [:]
    private unowned let app: AppModel
    private let bleObserver = BLEPassiveObserver()
    private var proximity = BLEProximityRuntime()
    private var runtime = AutomationRuntime(sessionStarted: Date().timeIntervalSince1970)
    private var task: Task<Void,Never>?
    private var working = false
    private var editors = 0
    private var sending = false
    private var trackingLocation = false
    private var lastNetworkRefresh = Date.distantPast
    private var background = false
    private var backgroundTask: Task<Void,Never>?
    private var backgroundGeneration = UUID()
    private let window = BackgroundExecutionWindow()
    private var lastWake = Date.distantPast
    private var outsideRadio = BLEBackgroundRearm()
    private var routeArrivals: [ObjectReference:AutomationReadiness] = [:]
    init(app: AppModel) { self.app = app }

    func setWorking(_ value: Bool) { working = value }
    func beginEditing() { editors += 1 }
    func endEditing() { editors = max(0,editors-1) }
    func resume() {
        guard app.canManageGuestAccess else { suspend(); return }
        backgroundGeneration = UUID()
        background = false; backgroundTask?.cancel(); backgroundTask = nil; window.end()
        guard task == nil else { return }
        bleObserver.onAdvertisement = { [weak self] bytes,rssi in self?.receiveBLE(bytes,rssi:rssi) }
        bleObserver.onDiscovery = { [weak self] row in self?.receiveDiscovery(row) }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    func suspend() {
        backgroundGeneration = UUID()
        background = false; backgroundTask?.cancel(); backgroundTask = nil; window.end()
        task?.cancel(); task = nil
        bleObserver.setEnabled(false); proximity = BLEProximityRuntime()
        if trackingLocation { app.automationSensors.trackLocation(enabled:false,background:false) }
        trackingLocation = false
        readiness.removeAll()
        routeArrivals.removeAll(); outsideRadio.reset()
        // A resumed session must observe a fresh outside entry. Neither stale
        // GPS/Wi-Fi nor a process restart is an automatic command retry.
        runtime = AutomationRuntime(sessionStarted:Date().timeIntervalSince1970)
    }
    func pauseForBackground() {
        backgroundGeneration = UUID()
        task?.cancel(); task = nil; backgroundTask?.cancel(); backgroundTask = nil; window.end()
        // Keep genuine route history and durable BLE disarm state across the
        // scene transition. Ending a foreground session is not a physical exit.
        sending = false
    }
    func enterBackground() {
        background = true
        let contexts = app.controlObjects.compactMap { try? app.automationContext(.object($0.target)) }
        bleObserver.onAdvertisement = { [weak self] bytes,rssi in self?.receiveBLE(bytes,rssi:rssi) }
        bleObserver.onDiscovery = { [weak self] row in self?.receiveDiscovery(row) }
        bleObserver.setEnabled(CBManager.authorization == .allowedAlways && contexts.contains { $0.isBLE && $0.template.bleEnabled })
        let needsGeo = contexts.contains { $0.template.geoEnabled }
        if needsGeo {
            let sensors = app.automationSensors
            sensors.onLocation = { [weak self] location in self?.receive(location) }
            let allowed = sensors.locationAuthorization == .authorizedAlways
            sensors.trackLocation(enabled:allowed,background:allowed); trackingLocation = allowed
        } else if trackingLocation {
            app.automationSensors.trackLocation(enabled:false,background:false); trackingLocation = false
        }
    }
    private func wake(bluetooth: Bool) {
        guard background, app.canObserveAutomation, backgroundTask == nil, Date().timeIntervalSince(lastWake) >= 0.5 else { return }
        let generation = UUID(); backgroundGeneration = generation
        let seconds: TimeInterval = bluetooth ? 8 : 20
        guard window.begin(seconds:seconds,expiration:{ [weak self] in
            guard self?.backgroundGeneration == generation else { return }
            self?.app.stopBackgroundCommand(); self?.backgroundTask?.cancel()
        }) else { return }
        lastWake = Date()
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.backgroundGeneration == generation {
                    self.app.endBackgroundAutomatic(); self.window.end(); self.backgroundTask = nil
                }
            }
            if self.app.controlObjects.contains(where:{ (try? self.app.automationContext(.object($0.target)).template.wifiEnabled) == true }) {
                self.app.automationSensors.refreshNetwork()
            }
            await self.tick(backgroundDuration:seconds)
        }
    }
    func receive(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) <= 30 else { return }
        runtime.receive(AutomationLocationFix(latitude:location.coordinate.latitude,longitude:location.coordinate.longitude,
            accuracyM:Float(location.horizontalAccuracy),speedMps:Float(location.speed),
            timestampMS:Int64(max(0,location.timestamp.timeIntervalSince1970*1000))))
        // Feed every real batched fix through the corridor matcher in order.
        // Keep a fresh arrival until the wake task runs; historical fixes may
        // rebuild the route buffer but cannot become a delayed physical action.
        for entry in app.controlObjects {
            guard let context = try? app.automationContext(.object(entry.target)), context.template.geoEnabled,
                  context.template.geoMode == "route" else { continue }
            let result = inspect(entry.target,template:context.template,isBLE:context.isBLE)
            if result.routeMatched, abs(location.timestamp.timeIntervalSinceNow) <= 2 { routeArrivals[entry.target] = result }
        }
        if background { wake(bluetooth:false) }
    }
    func inspect(_ target: ObjectReference, template: AutomationTemplate, isBLE: Bool, date: Date = Date()) -> AutomationReadiness {
        var network: AutomationWiFiNetwork?
        if template.wifiEnabled, let observed = app.automationSensors.networkObservedAt,
           date.timeIntervalSince(observed) >= 0, date.timeIntervalSince(observed) <= 15 {
            network = app.automationSensors.network
        }
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
            bleReady:isBLE ? (proximity.sample(target.id,at:date.timeIntervalSince1970)?.near(radiusM:template.bleRadiusM,at:date.timeIntervalSince1970) == true) : nil)
        if !isBLE, let arrival = routeArrivals[target], arrival.template == template,
           date >= arrival.evaluatedAt, date.timeIntervalSince(arrival.evaluatedAt) <= 2 { return arrival }
        return isBLE ? result.forBLE(armed:!app.bleAutomationDisarmed.contains(target.id)) : result
    }
    func resetBLEContinuity() { proximity.suspend() }
    func bleOpenish(_ target: ObjectReference, date: Date = Date()) -> Bool {
        proximity.sample(target.id,at:date.timeIntervalSince1970)?.observation.openish == true
    }
    func blePosition(_ target: ObjectReference, date: Date = Date()) -> String? {
        proximity.sample(target.id,at:date.timeIntervalSince1970)?.observation.position
    }
    func receiveBLE(_ payload: Data, rssi: Int) {
        guard app.canObserveAutomation else { return }
        let now = Date().timeIntervalSince1970
        if background {
            // iOS coalesces background advertisements. A silent interval is not
            // evidence of leaving radio range, and must NEVER rearm a FIRE.
            proximity.suspend()
        }
        for entry in app.controlObjects where entry.kind == "ble" {
            guard let observation = try? app.authenticatedBLEObservation(entry,payload:payload) else { continue }
            let rearm = proximity.receive(key:entry.target.id,observation:observation,rssi:rssi,now:now)
            let backgroundRearm: Bool
            if background, let template = try? app.automationContext(.object(entry.target)).template {
                backgroundRearm = outsideRadio.receive(key:entry.target.id,rssi:rssi,radiusM:template.bleRadiusM,now:now)
            } else { backgroundRearm = false }
            if (rearm || backgroundRearm) && !app.bleControl.busy && !app.bleGuestControl.busy { try? app.setBLEAutomationArmed(entry.target,armed:true) }
            app.noteBLESighting(entry.target,sleepSeconds:observation.sleepSeconds)
        }
        if background { wake(bluetooth:true) }
    }
    private func receiveDiscovery(_ row: BLEDiscovery) {
        guard let payload = row.manufacturerPayload, app.canObserveAutomation,
              app.controlObjects.contains(where:{ (try? app.authenticatedBLEObservation($0,payload:payload)) != nil }) else { return }
        let now = Date()
        app.bleControl.noteDiscovery(row,at:now); app.bleGuestControl.noteDiscovery(row,at:now)
        receiveBLE(payload,rssi:row.rssi)
    }
    func consume(_ target: ObjectReference, route: Bool, date: Date = Date()) {
        routeArrivals.removeValue(forKey:target); runtime.consume(target.id,route:route,at:date)
    }
    private func tick(backgroundDuration: TimeInterval? = nil) async {
        guard app.canObserveAutomation, !Task.isCancelled else { return }
        let entries = app.controlObjects
        var contexts: [(CatalogObject,AutomationSettingsContext)] = []
        for entry in entries {
            if let context = try? app.automationContext(.object(entry.target)) { contexts.append((entry,context)) }
        }
        if !background { bleObserver.setEnabled(contexts.contains { $0.1.isBLE }) }
        let needsGeo = contexts.contains { $0.1.template.geoEnabled }
        if !background && needsGeo != trackingLocation {
            if needsGeo { app.automationSensors.onLocation = { [weak self] location in self?.receive(location) } }
            app.automationSensors.trackLocation(enabled:needsGeo,background:false); trackingLocation = needsGeo
        }
        if contexts.contains(where:{ $0.1.template.wifiEnabled }), Date().timeIntervalSince(lastNetworkRefresh) >= 10 {
            app.automationSensors.refreshNetwork(); lastNetworkRefresh = Date()
        }
        let targets = Set(entries.map(\.target))
        runtime.retain(Set(targets.map(\.id))); proximity.retain(Set(targets.map(\.id)))
        readiness = readiness.filter { targets.contains($0.key) }
        app.automaticConsumedAt = app.automaticConsumedAt.filter { targets.contains($0.key) }
        for (entry,context) in contexts {
            let result = inspect(entry.target,template:context.template,isBLE:context.isBLE)
            if readiness[entry.target] != result { readiness[entry.target] = result }
            guard result.ready else { continue }
            if context.isBLE && (!context.template.bleEnabled || app.bleAutomationDisarmed.contains(entry.target.id)) { continue }
            if context.isBLE && bleOpenish(entry.target) {
                try? app.setBLEAutomationArmed(entry.target,armed:false); continue
            }
            let gated = context.template.authEnabled || context.template.confirmEnabled || context.template.requireConfirmation == true
            if context.isBLE && gated {
                // BleScanReceiver: an object protected with PIN/confirmation is
                // manual-only, in foreground too. Do not invent an auto dialog.
                try? app.setBLEAutomationArmed(entry.target,armed:false); continue
            }
            // Android consumes a route seen while editing/on another tab, so
            // switching back later does not unexpectedly open the old arrival.
            if (!background && !working && !context.isBLE) || editors > 0 || app.hasTaskDialog {
                if result.routeMatched { consume(entry.target,route:true) }
                continue
            }
            guard !sending, !app.busy, !app.ownerBusy, !app.blePairing.busy else { continue }
            sending = true
            if background, let duration = backgroundDuration {
                guard window.valid else { sending = false; return }
                if let scopeID = app.beginBackgroundAutomatic(entry,readiness:result,duration:min(duration,window.remaining)) {
                    await app.performAutomaticAction(entry,readiness:result)
                    app.endBackgroundAutomatic(scopeID)
                } else if !context.isBLE {
                    // iOS cannot silently dial a SIM call or maintain Android's
                    // permanent host service. Bring the person to the ordinary
                    // protected card instead of claiming a physical success.
                    consume(entry.target,route:result.routeMatched)
                    await AutomationNotifications.show(label:app.objectLabel(entry),target:entry.target)
                }
            } else { await app.performAutomaticAction(entry,readiness:result) }
            sending = false
        }
    }
}

extension AppModel {
    func automaticPermitValid(_ target: ObjectReference, date: Date = Date()) -> Bool {
        guard let permit = automaticPermits[target] else { return false }
        return automaticEvidenceValid(permit,target:target,date:date,maximumAge:actionPromptRetainsAutomaticEvidence(target) ? 30 : 2)
    }
    func automaticEvidenceValid(_ permit: AutomationReadiness, target: ObjectReference, date: Date = Date(), maximumAge: TimeInterval = 30) -> Bool {
        guard allowsAction(target,automatic:true), permit.ready, date >= permit.evaluatedAt,
              date.timeIntervalSince(permit.evaluatedAt) <= maximumAge,
              let context = try? automationContext(.object(target)), context.template == permit.template else { return false }
        if permit.routeMatched { return true }
        return conditionReadiness(target,date:date)?.satisfies(permit.template,at:date) == true
    }
    func noteAutomationAttempt(_ target: ObjectReference) {
        noteCameraAction(target)
        guard let context = try? automationContext(.object(target)) else { return }
        automation.consume(target,route:context.template.geoMode == "route")
    }
    func conditionReadiness(_ target: ObjectReference, date: Date = Date()) -> AutomationReadiness? {
        guard let context = try? automationContext(.object(target)),
              context.template.geoEnabled || context.template.wifiEnabled || context.template.timeEnabled || context.template.bleEnabled else { return nil }
        return automation.inspect(target,template:context.template,isBLE:context.isBLE,date:date)
    }
    func performAutomaticAction(_ entry: CatalogObject, readiness: AutomationReadiness) async {
        guard allowsAction(entry.target,automatic:true), !busy, !ownerBusy, !hasTaskDialog,
              let context = try? automationContext(.object(entry.target)), context.template == readiness.template,
              (automaticConsumedAt[entry.target].map { readiness.evaluatedAt > $0 } ?? true),
              readiness.ready, Date() >= readiness.evaluatedAt, Date().timeIntervalSince(readiness.evaluatedAt) <= 2 else { return }
        let gated = context.template.authEnabled || context.template.confirmEnabled || context.template.requireConfirmation == true
        if context.isBLE && gated {
            try? setBLEAutomationArmed(entry.target,armed:false); return
        }
        automaticPermits[entry.target] = readiness
        var retainedForPrompt = false
        defer { if !retainedForPrompt { automaticPermits.removeValue(forKey:entry.target) } }
        switch entry {
        case .owned(let owner,let object):
            guard let intent = ownerActionIntent(server:owner.server,objectID:object.id,automatic:true) else { return }
            if context.isBLE {
                guard context.template.bleEnabled, !bleAutomationDisarmed.contains(entry.target.id), !automation.bleOpenish(entry.target) else { return }
                do { try setBLEAutomationArmed(entry.target,armed:false) } catch { return }
            }
            automaticConsumedAt[entry.target] = readiness.evaluatedAt
            AppSoundCenter.shared.play(.geo)
            if !context.isBLE { automation.consume(entry.target,route:readiness.routeMatched) }
            if gated { actionPrompt = .owner(intent); retainedForPrompt = true }
            else { await execute(intent) }
        case .received(let guest,let object):
            guard let intent = actionIntent(guestID:guest.id,object:object,automatic:true) else { return }
            if context.isBLE {
                guard context.template.bleEnabled, !bleAutomationDisarmed.contains(entry.target.id), !automation.bleOpenish(entry.target) else { return }
                do { try setBLEAutomationArmed(entry.target,armed:false) } catch { return }
            }
            automaticConsumedAt[entry.target] = readiness.evaluatedAt
            AppSoundCenter.shared.play(.geo)
            if !context.isBLE { automation.consume(entry.target,route:readiness.routeMatched) }
            if gated { actionPrompt = .guest(intent); retainedForPrompt = true }
            else { await execute(intent) }
        }
    }
}

extension AppModel {
    func authenticatedBLEObservation(_ entry: CatalogObject, payload: Data) throws -> AuthenticatedBLEObservation {
        switch entry {
        case .owned(let owner,let object):
            guard ownerAccessIsUsable(owner.server), object.kind == "ble", object.ownerCardAvailable, !owner.isMoving(object.id),
                  let wrapped = object.wrappedBLESecret, let did = object.bleDeviceID else { throw BLETransportFailure.cancelled }
            let secret = try GuestCrypto.decrypt(key:owner.masterKey,envelope:wrapped)
            let observation = try AuthenticatedBLEObservation.owner(payload:payload,secret:secret)
            guard observation.deviceID == did else { throw BLETransportFailure.invalidValue }
            if let info = try? BLEDeviceInformation(payload:payload,ownerSecret:secret) { bleInformation[entry.target] = info }
            return observation
        case .received(let guest,let object):
            guard !guest.paused, object.kind == "ble", let cache = guest.bleCache else { throw BLETransportFailure.cancelled }
            let material = try cache.open(key:guest.invite.bundleKey)
            let epoch = max(cache.maximumEpoch,UInt64(max(0,Date().timeIntervalSince1970)))
            let grant = try GuestActionPolicy.decodeBLE(bundle:material.bundle,numberID:object.numberID,epoch:epoch,overrides:guest.automation?[object.id]).grant
            guard !(cache.revocations ?? []).contains(where: { $0.deviceID == grant.deviceID && $0.guestID == grant.guestID && $0.revoked }) else { throw BLETransportFailure.cancelled }
            return try AuthenticatedBLEObservation.guest(payload:payload,grant:grant,epoch:epoch)
        }
    }
}
