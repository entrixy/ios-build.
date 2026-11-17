import Foundation
import Combine
import EntrixyCore

@MainActor final class BLEPairingModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var discoveries: [BLEDiscovery] = []
    @Published private(set) var message: String?
    private unowned let app: AppModel
    private let transport: any BLECentralTransport
    private var generation = UUID()
    init(app: AppModel, transport: (any BLECentralTransport)? = nil) {
        self.app = app; self.transport = transport ?? CoreBluetoothTransport()
    }
    func suspend() {
        generation = UUID(); transport.stop(); busy = false
        discoveries = []
        message = "Операция остановлена при выходе из приложения. Сохранённую привязку можно проверить повторным поиском."
    }
    func scan() async {
        guard !busy, app.canManageGuestAccess else { return }
        busy = true; message = "Поиск контроллеров поблизости…"
        let current = UUID(); generation = current
        defer { if generation == current { busy = false } }
        do {
            let found = try await transport.scan(seconds: 8)
            guard generation == current, app.canManageGuestAccess else { return }
            discoveries = found
            message = found.isEmpty ? "Контроллеры не найдены. Поднесите iPhone ближе и включите режим привязки на контроллере." : "Выберите свой контроллер в режиме привязки. Название и уровень сигнала сами по себе не подтверждают его подлинность."
        } catch { if generation == current { message = error.localizedDescription } }
    }
    func pair(discoveryID: UUID, server: String, label: String) async {
        guard !busy, app.canManageGuestAccess, !app.ownerBusy,
              let owner = app.owners.first(where: { $0.server == server && $0.ownershipLost != true }), owner.credentials != nil,
              !(owner.blePairings ?? []).contains(where: { $0.peripheralID == discoveryID }) else { return }
        busy = true; message = "Подключение для привязки…"
        let current = UUID(); generation = current
        defer { if generation == current { busy = false } }
        var channel: (any BLEChannel)?
        var persisted = false
        do {
            let connection = try await transport.connect(discoveryID, pairing: true); channel = connection
            let peerPublic = try await connection.read(BLECrypto.pairPublicCharacteristic)
            guard generation == current, app.canManageGuestAccess, app.ownerAccessIsUsable(server) else { throw BLETransportFailure.cancelled }
            let reserved = Set((owner.blePairings ?? []).map(\.deviceID) + (owner.objects ?? []).compactMap(\.bleDeviceID))
            var deviceID: UInt32 = 0
            repeat { deviceID = GuestCrypto.randomBytes(count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } } while deviceID == 0 || reserved.contains(deviceID)
            var record = try BLEPairingRecord(masterKey: owner.masterKey, peripheralID: discoveryID,
                peerPublic: peerPublic, deviceID: deviceID, label: label)
            try app.saveBLEPairing(record, server: server); persisted = true
            try record.markSent()
            try app.saveBLEPairing(record, server: server)
            guard generation == current, app.canManageGuestAccess, app.ownerAccessIsUsable(server) else { throw BLETransportFailure.cancelled }
            try await connection.write(record.packet, to: BLECrypto.pairDoneCharacteristic)
            await connection.close(); channel = nil
            guard generation == current else { return }
            message = "Запись привязки отправлена. Проверьте её поиском: подтверждение требует подписанного объявления контроллера."
        } catch {
            if let channel { await channel.close() }
            guard generation == current else { return }
            message = persisted ? "Исход привязки не подтверждён. Секрет сохранён; нажмите «Проверить привязку». Повторная запись не выполняется." : error.localizedDescription
        }
    }
    func sendPrepared(pairingID: UUID, server: String) async {
        guard !busy, app.canManageGuestAccess, !app.ownerBusy,
              let owner = app.owners.first(where: { $0.server == server && $0.ownershipLost != true }),
              var record = owner.blePairings?.first(where: { $0.id == pairingID }), record.phase == .prepared else { return }
        busy = true; message = "Продолжение сохранённой привязки…"
        let current = UUID(); generation = current
        defer { if generation == current { busy = false } }
        var channel: (any BLEChannel)?
        do {
            // CoreBluetooth peripheral identifiers are local to an installation;
            // after migration, require rediscovery of this exact prepared peer.
            _ = try await transport.scan(seconds: 5)
            guard generation == current else { return }
            let connection = try await transport.connect(record.peripheralID, pairing: true); channel = connection
            let publicKey = try await connection.read(BLECrypto.pairPublicCharacteristic)
            guard publicKey == record.peerPublic, generation == current, app.canManageGuestAccess else { throw BLETransportFailure.invalidValue }
            try record.markSent(); try app.saveBLEPairing(record, server: server)
            try await connection.write(record.packet, to: BLECrypto.pairDoneCharacteristic)
            await connection.close(); channel = nil
            if generation == current { message = "Запись отправлена. Проверьте подпись контроллера поиском." }
        } catch {
            if let channel { await channel.close() }
            if generation == current { message = "Привязка не подтверждена. Сохранённый ключ не изменён. " + error.localizedDescription }
        }
    }
    func check(pairingID: UUID, server: String) async {
        guard !busy, app.canManageGuestAccess,
              let owner = app.owners.first(where: { $0.server == server && $0.ownershipLost != true }),
              var record = owner.blePairings?.first(where: { $0.id == pairingID }), record.phase != .prepared else { return }
        busy = true; message = "Проверка подписи контроллера…"
        let current = UUID(); generation = current
        defer { if generation == current { busy = false } }
        do {
            let found = try await transport.scan(seconds: 10)
            guard generation == current, app.canManageGuestAccess else { return }
            let valid = found.compactMap(\.manufacturerPayload).first { payload in
                var candidate = record
                return (try? candidate.confirm(advertisement: payload, masterKey: owner.masterKey)) != nil
            }
            guard let valid else {
                message = "Подписанное объявление не найдено. Поднесите iPhone ближе и разбудите контроллер. Сохранённый секрет не изменён."
                return
            }
            try record.confirm(advertisement: valid, masterKey: owner.masterKey)
            try app.saveBLEPairing(record, server: server)
            message = "Привязка подтверждена подписью контроллера. Объект можно добавить на сервер."
        } catch { if generation == current { message = error.localizedDescription } }
    }
}
