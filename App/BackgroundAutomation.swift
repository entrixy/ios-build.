import Foundation
import UIKit
import CoreBluetooth
import CoreLocation
import EntrixyCore

/// Both a normal scene and a genuine OS location/Bluetooth relaunch share one
/// protected model. A restored pending command is never resumed.
@MainActor enum LiveAppRuntime {
    private static var retained: AppModel?
    static func model() -> AppModel {
        if let retained { return retained }
        let app = AppModel(privacyRouter:ServerPrivacyRouter()); retained = app; return app
    }
}

@MainActor final class EntrixyLifecycleDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        AppNotificationRouting.shared.install()
        if launchOptions?[.location] != nil || launchOptions?[.bluetoothCentrals] != nil {
            // Keychain failure/first boot cannot generate a replacement identity
            // or grant authority; the model's ordinary storage guards apply.
            LiveAppRuntime.model().enterBackground()
        }
        return true
    }
}

/// UIKit can refuse/expire a wake window. Revocation precedes transport
/// cancellation so a late nonce/read callback cannot authorize a FIRE write.
@MainActor final class BackgroundExecutionWindow {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var timer: Task<Void,Never>?
    private var onExpiration: (() -> Void)?
    private var active = false
    private var deadline: TimeInterval = 0
    var remaining: TimeInterval { active ? max(0,deadline-ProcessInfo.processInfo.systemUptime) : 0 }
    var valid: Bool { remaining > 0 }
    func begin(seconds: TimeInterval, expiration: @escaping () -> Void) -> Bool {
        end(); onExpiration = expiration
        identifier = UIApplication.shared.beginBackgroundTask(withName:"Entrixy configured automation") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        guard identifier != .invalid else { onExpiration = nil; return false }
        active = true; deadline = ProcessInfo.processInfo.systemUptime + seconds
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) } catch { return }
            self?.expire()
        }
        return true
    }
    private func expire() { active = false; let callback = onExpiration; onExpiration = nil; callback?(); end() }
    func end() {
        active = false; timer?.cancel(); timer = nil; onExpiration = nil
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
    }
}

extension AppModel {
    var automationIsForeground: Bool { isForeground }
    var canObserveAutomation: Bool { canManageGuestAccess || (backgroundMonitoring && storageAllowsAutomation) }
    func allowsAction(_ target: ObjectReference, automatic: Bool) -> Bool {
        if canManageGuestAccess { return true }
        guard automatic, backgroundMonitoring, storageAllowsAutomation,
              let scope = backgroundActionScope, let context = try? automationContext(.object(target)),
              let entry = controlObjects.first(where:{ $0.target == target }), backgroundTransport(entry) == scope.transport,
              scope.allows(target,template:context.template,uptime:ProcessInfo.processInfo.systemUptime) else { return false }
        return true
    }
    func backgroundTransport(_ entry: CatalogObject) -> BackgroundActionScope.Transport? {
        if entry.kind == "ble" { return .bluetooth }
        if case let .owned(_,object) = entry, object.kind == "webhook", object.routing["webhook_mode"] == "phone" { return .localWebhook }
        return nil
    }
    func beginBackgroundAutomatic(_ entry: CatalogObject, readiness: AutomationReadiness, duration: TimeInterval) -> UUID? {
        guard backgroundMonitoring, !isForeground, storageAllowsAutomation, backgroundActionScope == nil,
              let transport = backgroundTransport(entry), let context = try? automationContext(.object(entry.target)),
              context.template == readiness.template, readiness.ready, Date() >= readiness.evaluatedAt,
              Date().timeIntervalSince(readiness.evaluatedAt) <= 2,
              let scope = try? BackgroundActionScope(target:entry.target,transport:transport,template:context.template,
                uptime:ProcessInfo.processInfo.systemUptime,duration:duration) else { return nil }
        backgroundActionScope = scope; return scope.id
    }
    func endBackgroundAutomatic(_ id: UUID? = nil) {
        guard id == nil || backgroundActionScope?.id == id else { return }
        backgroundActionScope = nil
    }
    func stopBackgroundCommand() {
        endBackgroundAutomatic()
        bleControl.suspend(); bleGuestControl.suspend(); ownerControl.suspend()
    }
    /// Called only at a real scene/background boundary, never to pretend that
    /// the app is in foreground. Existing manual sessions are always stopped.
    func enterBackground() {
        let eligible = storageAllowsAutomation && controlObjects.contains { entry in
            guard let context = try? automationContext(.object(entry.target)) else { return false }
            return context.template.geoEnabled || (context.isBLE && context.template.bleEnabled)
        }
        suspend(preserveAutomation:eligible)
        backgroundMonitoring = eligible
        if eligible { automation.enterBackground() }
    }
}
