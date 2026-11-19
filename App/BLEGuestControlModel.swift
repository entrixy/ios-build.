import Foundation
import Combine
import EntrixyCore

@MainActor final class BLEGuestControlModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var messages: [String: String] = [:]
    private unowned let app: AppModel
    private let transport: any BLECentralTransport
    private var generation = UUID()
    private var activeGuest: String?
    init(app: AppModel, transport: (any BLECentralTransport)? = nil) {
        self.app = app; self.transport = transport ?? CoreBluetoothTransport()
    }
    func noteDiscovery(_ row: BLEDiscovery, at date: Date) { transport.prime(row,at:date) }
    func cancel(guestID: String) { if activeGuest == guestID { suspend() } }
    func suspend() {
        generation = UUID(); busy = false; activeGuest = nil; transport.stop()
    }
    /// AppModel alone grants the single-use authorization consumed by the
    /// protected journal/proof transaction immediately before FIRE.
    func execute(_ intent: ActionIntent) async {
        guard !busy, app.isBLEGuestAuthorized(intent.id) else { return }
        busy = true; activeGuest = intent.guestID
        let key = intent.guestID + "|" + intent.object.id
        let current = UUID(); generation = current
        defer {
            app.finishBLEGuestAuthorization(intent.id); app.automation.resetBLEContinuity()
            if generation == current { busy = false; activeGuest = nil }
        }
        var channel: (any BLEChannel)?
        var actionKey: String?
        do {
            let grant = try app.guestBLEMaterial(intent)
            messages[key] = "Поиск Bluetooth-контроллера…"
            let found = try await transport.scan(seconds: 5)
            guard generation == current else { throw BLETransportFailure.cancelled }
            let matching = found.filter { discovery in
                guard let payload = discovery.manufacturerPayload,
                      (try? BLECrypto.advertisementDeviceID(payload)) == grant.deviceID else { return false }
                // Guests do not receive the owner secret. On v3 state frames,
                // additionally authenticate the state trailer when available.
                if payload.count == 24, let stateKey = grant.stateKey { return (try? BLECrypto.state(payload, stateKey: stateKey)) != nil }
                return true
            }.sorted { $0.rssi > $1.rssi }
            guard let discovery = matching.first else { messages[key] = "Контроллер не найден. Поднесите iPhone ближе и разбудите его."; return }
            if intent.automatic {
                guard let bytes = discovery.manufacturerPayload else { throw BLETransportFailure.invalidValue }
                let observation = try AuthenticatedBLEObservation.guest(payload:bytes,grant:grant,epoch:UInt64(max(0,Date().timeIntervalSince1970)))
                if observation.openish { return }
            }
            app.noteBLESighting(.received(guestID: intent.guestID, objectID: intent.object.id))
            _ = try app.guestBLEMaterial(intent)
            let connection = try await transport.connect(discovery.id, pairing: false); channel = connection
            let hasResults = try await connection.enableResults()
            let decisions = try app.guestBLERevocations(intent).filter { $0.deviceID == grant.deviceID && $0.controllerResult == nil }
                .sorted { a, b in a.guestID == grant.guestID && b.guestID != grant.guestID ? true : (b.guestID == grant.guestID && a.guestID != grant.guestID ? false : a.version > b.version) }
            guard decisions.isEmpty || hasResults else { throw BLETransportFailure.unsupported }
            let maintenanceStarted = uptime()
            for decision in decisions.prefix(16) {
                guard generation == current, uptime() - maintenanceStarted < 20, app.isBLEGuestAuthorized(intent.id) else { throw BLETransportFailure.cancelled }
                guard try app.guestBLERevocations(intent).contains(where: { $0.id == decision.id && $0.version == decision.version && $0.signature == decision.signature }) else { throw BLETransportFailure.cancelled }
                messages[key] = "Передача настроек доступа контроллеру…"
                try await connection.write(decision.frame, to: BLECrypto.revokeCharacteristic)
                let code = try await wait(connection.results, family: .revoke)
                guard code == 0x40 || code == 0x41 else { throw BLETransportFailure.invalidValue }
                try app.saveGuestBLEReceipt(intent, record: decision, code: code)
            }
            guard decisions.count <= 16 else { throw BLETransportFailure.busy }
            guard generation == current else { throw BLETransportFailure.cancelled }
            _ = try app.guestBLEMaterial(intent)
            // Establish controller time once before FIRE. Never fix clock errors
            // by replaying a physical command. Every NONCE read is fresh in FW.
            let timeNonce = try await connection.read(BLECrypto.nonceCharacteristic)
            let epoch = UInt64(max(0, Date().timeIntervalSince1970))
            guard grant.isValid(at: epoch), generation == current, app.isBLEGuestAuthorized(intent.id) else { throw BLECommandSession.Failure.expired }
            let time = try BLECrypto.guestTime(token: grant.token, ownerSignature: grant.ownerSignature,
                guestKey: grant.guestKey, epochMilliseconds: epoch * 1000, nonce: timeNonce)
            try await connection.write(time, to: BLECrypto.timeCharacteristic)
            if hasResults {
                let status = try await wait(connection.results, family: .time)
                // 0x17 means the clock was synchronized recently; FW intentionally
                // requires a recent FIRE before another guest time adjustment.
                guard status == 0x11 || status == 0x17 else { throw BLETransportFailure.invalidValue }
            }
            let freshGrant = try app.guestBLEMaterial(intent)
            guard freshGrant == grant, generation == current else { throw BLETransportFailure.cancelled }
            let nonce = try await connection.read(BLECrypto.nonceCharacteristic)
            guard generation == current else { throw BLETransportFailure.cancelled }
            var session = try BLECommandSession(credential: .guest(grant), now: uptime(), epoch: epoch)
            try session.prepare(nonce: nonce, now: uptime(), epoch: currentEpoch())
            let frame = try session.consume(now: uptime(), epoch: currentEpoch())
            guard let proof = session.proofHash else { throw BLETransportFailure.invalidValue }
            actionKey = try app.beginBLEGuestAction(intent, proofHash: proof)
            guard generation == current,
                  app.allowsAction(.received(guestID:intent.guestID,objectID:intent.object.id),automatic:intent.automatic) else { throw BLETransportFailure.cancelled }
            messages[key] = "Отправка одного импульса…"
            try await connection.write(frame, to: BLECrypto.fireCharacteristic)
            guard generation == current else { await connection.close(); return }
            if hasResults {
                let code = try await wait(connection.results, family: .fire)
                guard generation == current, let result = session.receive(code) else { throw BLETransportFailure.cancelled }
                messages[key] = result.message
                if let actionKey { app.actionResult(actionKey: actionKey, result: result.message, level: result.succeeded ? "success" : "error", replace: true) }
            } else {
                let text = "Запись отправлена. Эта версия контроллера не подтверждает результат команды."
                messages[key] = text
                if let actionKey { app.actionResult(actionKey: actionKey, result: text, level: "warning", replace: true) }
            }
            await connection.close()
        } catch {
            if let channel { await channel.close() }
            guard generation == current else { return }
            let text = actionKey == nil ? "Bluetooth-команда не отправлена. " + error.localizedDescription
                : "Результат Bluetooth-команды неизвестен. Автоматического повтора не будет."
            messages[key] = text
            if let actionKey { app.actionResult(actionKey: actionKey, result: text, level: "warning", replace: true) }
        }
    }
    private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func currentEpoch() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970)) }
    private enum ResultFamily { case time, revoke, fire }
    private func wait(_ stream: AsyncThrowingStream<UInt8, Error>, family: ResultFamily) async throws -> UInt8 {
        try await withThrowingTaskGroup(of: UInt8.self) { group in
            group.addTask {
                for try await code in stream {
                    switch family {
                    case .time: if (0x10...0x1f).contains(code) { return code }
                    case .revoke: if (0x40...0x4f).contains(code) { return code }
                    case .fire: if BLEFireResult(rawValue: code) != nil { return code }
                    }
                }
                throw BLETransportFailure.disconnected
            }
            group.addTask { try await Task.sleep(nanoseconds: 8_000_000_000); throw BLETransportFailure.timeout }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw BLETransportFailure.disconnected }
            return result
        }
    }
}
