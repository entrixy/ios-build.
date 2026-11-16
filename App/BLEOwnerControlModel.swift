import Foundation
import Combine
import EntrixyCore

/// Explicit owner pulse/toggle only. No scheduled actions, reconnect or replay.
@MainActor final class BLEOwnerControlModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var deliveryMessages: [UInt32: String] = [:]
    @Published private(set) var messages: [UUID: String] = [:]
    private unowned let app: AppModel
    private let transport: any BLECentralTransport
    private var generation = UUID()
    private var currentObject: UUID?
    init(app: AppModel, transport: (any BLECentralTransport)? = nil) {
        self.app = app; self.transport = transport ?? CoreBluetoothTransport()
    }
    func suspend() {
        generation = UUID(); transport.stop(); busy = false
        if let currentObject { messages[currentObject] = "Операция остановлена. Отправленная команда автоматически не повторится." }
        currentObject = nil
    }
    func execute(server: String, objectID: UUID) async {
        guard !busy, app.canManageGuestAccess,
              let owner = app.owners.first(where: { $0.server == server }),
              let object = owner.objects?.first(where: { $0.id == objectID }), object.kind == "ble",
              object.ownerCardAvailable,
              let wrapped = object.wrappedBLESecret, let deviceID = object.bleDeviceID,
              app.ownerManualActionAllowed(object, server: server, action: .toggle) else { return }
        busy = true; currentObject = objectID
        let current = UUID(); generation = current
        defer { if generation == current { busy = false; currentObject = nil } }
        var channel: (any BLEChannel)?
        var actionKey: String?
        do {
            let secret = try GuestCrypto.decrypt(key: owner.masterKey, envelope: wrapped)
            messages[objectID] = "Поиск контроллера поблизости…"
            let found = try await transport.scan(seconds: 5)
            guard generation == current, app.canManageGuestAccess else { throw BLETransportFailure.cancelled }
            // Never connect by name alone. Owner-secret HMAC authenticates the
            // advertised DID, then a fresh GATT nonce is used for the one write.
            let matching = found.filter { discovery in
                guard let payload = discovery.manufacturerPayload,
                      let verified = try? BLECrypto.verifyAdvertisement(payload, ownerSecret: secret) else { return false }
                return verified.deviceID == deviceID
            }.sorted { $0.rssi > $1.rssi }
            guard let discovery = matching.first else {
            let advertisement = discovery.manufacturerPayload.flatMap { try? BLECrypto.verifyAdvertisement($0, ownerSecret: secret) }
            app.noteBLESighting(.owned(server: server, objectID: objectID), sleepSeconds: advertisement?.sleepSeconds)
                messages[objectID] = "Свой контроллер с подтверждённой подписью не найден. Поднесите iPhone ближе и разбудите контроллер."
                return
            }
            messages[objectID] = "Подключение Bluetooth…"
            let connection = try await transport.connect(discovery.id, pairing: false); channel = connection
            let hasResults = try await connection.enableResults()
            try await applyDecisions(connection, server: server, deviceID: deviceID, secret: secret, hasResults: hasResults, generation: current)
            let nonce = try await connection.read(BLECrypto.nonceCharacteristic)
            guard generation == current, app.canManageGuestAccess else { throw BLETransportFailure.cancelled }
            var session = try BLECommandSession(credential: .owner(secret), now: uptime(), epoch: epoch())
            try session.prepare(nonce: nonce, now: uptime(), epoch: epoch())
            let frame = try session.consume(now: uptime(), epoch: epoch())
            guard let proof = session.proofHash else { throw BLETransportFailure.invalidValue }
            actionKey = try app.beginBLEOwnerAction(server: server, objectID: objectID, proofHash: proof)
            // No suspension between durable intent and this sole fire write.
            messages[objectID] = "Отправка одного импульса…"
            try await connection.write(frame, to: BLECrypto.fireCharacteristic)
            guard generation == current else { await connection.close(); return }
            if hasResults {
                let code = try await waitForFireResult(connection.results)
                guard generation == current, let result = session.receive(code) else { throw BLETransportFailure.cancelled }
                messages[objectID] = result.message
                if let actionKey { app.actionResult(actionKey: actionKey, result: result.message, level: result.succeeded ? "success" : "error", replace: true) }
            } else {
                let message = "Запись отправлена. Эта версия контроллера не подтверждает результат команды."
                messages[objectID] = message
                if let actionKey { app.actionResult(actionKey: actionKey, result: message, level: "warning", replace: true) }
            }
            await connection.close()
        } catch {
            if let channel { await channel.close() }
            guard generation == current else { return }
            let message = actionKey == nil ? error.localizedDescription : "Результат Bluetooth-команды неизвестен. Автоматического повтора не будет."
            messages[objectID] = message
            if let actionKey { app.actionResult(actionKey: actionKey, result: message, level: "warning", replace: true) }
        }
    }
    func deliverDecisions(server: String, deviceID: UInt32) async {
        guard !busy, app.canManageGuestAccess,
              let owner = app.owners.first(where: { $0.server == server }) else { return }
        let object = ((owner.objects ?? []) + (owner.bleArchivedObjects ?? [])).first { $0.bleDeviceID == deviceID }
        let pairing = owner.blePairings?.first { $0.deviceID == deviceID && $0.phase == .confirmed }
        guard let wrapped = object?.wrappedBLESecret ?? pairing?.wrappedSecret else { return }
        busy = true; deliveryMessages[deviceID] = "Поиск контроллера…"
        let current = UUID(); generation = current
        defer { if generation == current { busy = false } }
        var channel: (any BLEChannel)?
        do {
            let secret = try GuestCrypto.decrypt(key: owner.masterKey, envelope: wrapped)
            let found = try await transport.scan(seconds: 5)
            guard generation == current, app.canManageGuestAccess else { throw BLETransportFailure.cancelled }
            guard let discovery = found.first(where: { row in
                guard let payload = row.manufacturerPayload, let verified = try? BLECrypto.verifyAdvertisement(payload, ownerSecret: secret) else { return false }
                return verified.deviceID == deviceID
            }) else { throw BLETransportFailure.unavailable }
            let connection = try await transport.connect(discovery.id, pairing: false); channel = connection
            let hasResults = try await connection.enableResults()
            try await applyDecisions(connection, server: server, deviceID: deviceID, secret: secret, hasResults: hasResults, generation: current)
            await connection.close()
            if generation == current { deliveryMessages[deviceID] = "Передача завершена. Подтверждения записей показаны ниже." }
        } catch {
            if let channel { await channel.close() }
            if generation == current { deliveryMessages[deviceID] = "Передача настроек не подтверждена. " + error.localizedDescription }
        }
    }
    private func applyDecisions(_ connection: any BLEChannel, server: String, deviceID: UInt32, secret: Data,
                                hasResults: Bool, generation current: UUID) async throws {
        let records = (app.owners.first(where: { $0.server == server })?.bleRevocations ?? [])
            .filter { $0.deviceID == deviceID && $0.controllerResult == nil }.sorted { $0.version > $1.version }
        guard records.isEmpty || hasResults else { throw BLETransportFailure.unsupported }
        let started = uptime()
        for record in records.prefix(16) {
            guard generation == current, app.canManageGuestAccess, uptime() - started < 20,
                  app.owners.first(where: { $0.server == server })?.bleRevocations?.contains(where: { $0.id == record.id && $0.version == record.version && $0.signature == record.signature }) == true,
                  try record.verify(ownerSecret: secret) else { throw BLETransportFailure.cancelled }
            try await connection.write(record.frame, to: BLECrypto.revokeCharacteristic)
            let code = try await waitForFireResult(connection.results, family: 0x40...0x4f)
            guard code == 0x40 || code == 0x41 else { throw BLETransportFailure.invalidValue }
            try app.saveOwnerBLEReceipt(server: server, record: record, code: code)
        }
        guard records.count <= 16 else { throw BLETransportFailure.busy }
    }
    private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func epoch() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970)) }
    private func waitForFireResult(_ stream: AsyncThrowingStream<UInt8, Error>, family: ClosedRange<UInt8>? = nil) async throws -> UInt8 {
        try await withThrowingTaskGroup(of: UInt8.self) { group in
            group.addTask {
                for try await code in stream {
                    if let family { if family.contains(code) { return code } }
                    else if BLEFireResult(rawValue: code) != nil { return code }
                }
                throw BLETransportFailure.disconnected
            }
            group.addTask { try await Task.sleep(nanoseconds: 10_000_000_000); throw BLETransportFailure.timeout }
            defer { group.cancelAll() }
            guard let code = try await group.next() else { throw BLETransportFailure.disconnected }
            return code
        }
    }
}
