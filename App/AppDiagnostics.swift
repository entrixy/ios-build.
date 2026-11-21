import Foundation
import Combine
import UIKit
import MetricKit
import EntrixyCore

struct DiagnosticConsent: Codable {
    var enabled = false
    var asked = false
    var acceptedAt: Date?
}
struct DiagnosticState: Codable {
    var consent = DiagnosticConsent()
    var reports: [DiagnosticReport] = []
    var events: [DiagnosticEvent] = []
    func validate() throws {
        guard reports.count <= 8, Set(reports.map(\.id)).count == reports.count,
              consent.enabled || reports.isEmpty,
              !consent.enabled || (consent.asked && consent.acceptedAt != nil),
              consent.acceptedAt.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 }) ?? true else { throw GuestCrypto.Failure.invalidEnvelope }
        for report in reports { try report.validate(); guard report.kind == .crash else { throw GuestCrypto.Failure.invalidEnvelope } }
        guard events.count <= 100 else { throw GuestCrypto.Failure.invalidEnvelope }
        try events.forEach { try $0.validate() }
        guard try JSONEncoder().encode(self).count <= 2_097_152 else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}
protocol DiagnosticStorage {
    func load() throws -> DiagnosticState
    func save(_ state: DiagnosticState) throws
}
struct FileDiagnosticStorage: DiagnosticStorage {
    private func folder() throws -> URL {
        var root = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("Diagnostics",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        return root
    }
    func load() throws -> DiagnosticState {
        let file = try folder().appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return DiagnosticState() }
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        let data = try handle.read(upToCount:2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { throw GuestCrypto.Failure.invalidEnvelope }
        let state = try JSONDecoder().decode(DiagnosticState.self,from:data); try state.validate(); return state
    }
    func save(_ state: DiagnosticState) throws {
        try state.validate()
        try JSONEncoder().encode(state).write(to:folder().appendingPathComponent("state.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
}

private final class DiagnosticSubscriber: NSObject, MXMetricManagerSubscriber {
    let receive: @Sendable (Date,[DiagnosticCrash]) -> Void
    init(receive: @escaping @Sendable (Date,[DiagnosticCrash]) -> Void) { self.receive = receive }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads.prefix(8) {
            let crashes = (payload.crashDiagnostics ?? []).prefix(8).compactMap {
                try? DiagnosticCrash(recordedAt:payload.timeStampEnd,stack:$0.callStackTree.jsonRepresentation())
            }
            if !crashes.isEmpty { receive(payload.timeStampBegin,crashes) }
        }
    }
}

@MainActor final class AppDiagnostics: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var ready = false
    @Published private(set) var sending = false
    @Published private(set) var message: String?
    private unowned let app: AppModel
    private let storage: DiagnosticStorage
    private let api: DiagnosticTransport
    private let usesMetricKit: Bool
    private var state = DiagnosticState()
    private var subscriber: DiagnosticSubscriber?
    private var active = false
    private var autoPaused = false
    private var attempted = Set<String>()
    private var operation = UUID()
    private var upload: Task<Void,Never>?
    init(app: AppModel,storage: DiagnosticStorage = FileDiagnosticStorage(),api: DiagnosticTransport = DiagnosticAPI(),usesMetricKit: Bool = true) {
        self.app = app; self.storage = storage; self.api = api; self.usesMetricKit = usesMetricKit
        do { state = try storage.load(); try state.validate(); enabled = state.consent.enabled; ready = true }
        catch { message = "ios_diag_storage_failed" }
    }
    func activate() {
        active = true
        if !ready {
            do { state = try storage.load(); try state.validate(); enabled = state.consent.enabled; ready = true; message = nil }
            catch { return }
        }
        configureSubscriber(); offerConsent(); flush()
    }
    func offerConsent() {
        if active && ready && !autoPaused && !state.consent.asked && app.canManageGuestAccess && !app.hasTaskDialog { app.diagnosticConsentPrompt = true }
    }
    func record(_ code: DiagnosticEvent.Code) {
        guard ready else { return }
        if let last = state.events.last,last.code == code,Date().timeIntervalSince(last.date) < 60 { return }
        var draft = state; draft.events.append(DiagnosticEvent(code:code)); draft.events = Array(draft.events.suffix(100))
        do { try storage.save(draft); state = draft } catch { message = "ios_diag_storage_failed" }
    }
    @discardableResult func setConsent(_ value: Bool) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        StageTwoInputTrace.record("diagnostic-consent-request",["requested":value,"ready":ready,"canManage":app.canManageGuestAccess,"enabledBefore":enabled])
        #endif
        guard ready,app.canManageGuestAccess else { return false }
        if !value { autoPaused = true; cancelUpload(); removeSubscriber() }
        var draft = state; draft.consent.asked = true; draft.consent.enabled = value
        if value {
            if !enabled || autoPaused { draft.consent.acceptedAt = Date() }
        } else { draft.consent.acceptedAt = nil; draft.reports = [] }
        do {
            try storage.save(draft); state = draft; enabled = value; autoPaused = false; message = nil
            #if DEBUG && targetEnvironment(simulator)
            StageTwoInputTrace.record("diagnostic-consent-saved",["enabled":enabled])
            #endif
            app.diagnosticConsentPrompt = false
            configureSubscriber(); flush(); return true
        } catch {
            if !value { app.diagnosticConsentPrompt = false }
            message = "ios_diag_storage_failed"; return false
        }
    }
    private func configureSubscriber() {
        guard usesMetricKit,active,enabled,!autoPaused,subscriber == nil else { return }
        let next = DiagnosticSubscriber { [weak self] begin,crashes in
            Task { @MainActor in self?.receive(crashes,periodBegin:begin) }
        }
        subscriber = next; MXMetricManager.shared.add(next)
    }
    private func removeSubscriber() {
        if let subscriber { MXMetricManager.shared.remove(subscriber) }
        subscriber = nil
    }
    func receive(_ crashes: [DiagnosticCrash],periodBegin: Date) {
        guard ready,enabled,!autoPaused,let accepted = state.consent.acceptedAt,periodBegin >= accepted,!crashes.isEmpty,
              crashes.allSatisfy({ $0.recordedAt >= periodBegin }) else { return }
        do {
            let report = try makeReport(.crash,crashes:Array(crashes.prefix(8)))
            var draft = state
            if draft.reports.contains(where:{ $0.crashes == report.crashes }) { return }
            draft.reports.append(report)
            while draft.reports.count > 8 { draft.reports.removeFirst() }
            while try JSONEncoder().encode(draft).count > 2_097_152 { draft.reports.removeFirst() }
            try storage.save(draft); state = draft; flush()
        } catch { message = "ios_diag_storage_failed" }
    }
    private func makeReport(_ kind: DiagnosticReport.Kind,crashes: [DiagnosticCrash] = []) throws -> DiagnosticReport {
        try DiagnosticReport(kind:kind,appVersion:Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            build:Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",osVersion:UIDevice.current.systemVersion,
            facts:app.diagnosticFacts(),crashes:crashes,events:state.events)
    }
    func sendManual() async {
        guard ready,!sending,app.canManageGuestAccess else { return }
        let token = operation; sending = true; message = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if operation == token { sending = false; upload = nil } }
            do {
                let crashes = enabled && !autoPaused ? Array(state.reports.flatMap(\.crashes).prefix(8)) : []
                try await api.send(makeReport(.manual,crashes:crashes))
                if operation == token && app.canManageGuestAccess { message = "ios_diag_sent" }
            } catch { if operation == token { message = "ios_diag_send_failed" } }
        }
        upload = task
        await withTaskCancellationHandler(operation:{ await task.value },onCancel:{ task.cancel() })
    }
    private func flush() {
        guard active,ready,enabled,!autoPaused,!sending,app.canManageGuestAccess else { return }
        let reports = state.reports.filter { !attempted.contains($0.id) }
        guard !reports.isEmpty else { return }
        let token = operation; sending = true
        upload = Task { [weak self] in
            guard let self else { return }
            defer { if operation == token { sending = false; upload = nil } }
            for report in reports {
                guard !Task.isCancelled,operation == token,enabled,!autoPaused,active,app.canManageGuestAccess else { return }
                attempted.insert(report.id)
                do {
                    try await api.send(report)
                    guard !Task.isCancelled,operation == token,enabled,!autoPaused else { return }
                    var draft = state; draft.reports.removeAll { $0.id == report.id }
                    try storage.save(draft); state = draft
                } catch { return } // Retain the protected report; no retry loop.
            }
        }
    }
    private func cancelUpload() { operation = UUID(); upload?.cancel(); upload = nil; sending = false }
    func pause() { active = false; cancelUpload() }
}
