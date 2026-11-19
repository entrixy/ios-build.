import Foundation
import CoreBluetooth
import EntrixyCore

struct BLEDiscovery: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    /// Manufacturer payload without the Bluetooth company identifier. Discovery
    /// alone never authenticates a controller.
    let manufacturerPayload: Data?
}

enum BLETransportFailure: LocalizedError {
    case unavailable, denied, busy, timeout, disconnected, unsupported, invalidValue, cancelled
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Включите Bluetooth и повторите поиск"
        case .denied: return "Разрешите Entrixy доступ к Bluetooth в настройках iPhone"
        case .busy: return "Дождитесь завершения текущего подключения Bluetooth"
        case .timeout: return "Время ожидания Bluetooth истекло. Команда автоматически не повторяется"
        case .disconnected: return "Связь с контроллером прервана. Результат отправленной команды неизвестен"
        case .unsupported: return "Контроллер не поддерживает необходимый протокол Entrixy"
        case .invalidValue: return "Контроллер вернул некорректные данные"
        case .cancelled: return "Операция Bluetooth отменена"
        }
    }
}

@MainActor protocol BLEChannel: AnyObject {
    var results: AsyncThrowingStream<UInt8, Error> { get }
    func enableResults() async throws -> Bool
    func read(_ characteristic: String) async throws -> Data
    func write(_ data: Data, to characteristic: String) async throws
    func close() async
}

@MainActor protocol BLECentralTransport: AnyObject {
    func prime(_ discovery: BLEDiscovery, at date: Date)
    func scan(seconds: TimeInterval) async throws -> [BLEDiscovery]
    func connect(_ discoveryID: UUID, pairing: Bool) async throws -> any BLEChannel
    func stop()
}
extension BLECentralTransport { func prime(_ discovery: BLEDiscovery, at date: Date) {} }

/// Shared manual/scoped-automatic transport. The manager is created only on an
/// authorized operation, so constructing the app never requests permission.
@MainActor final class CoreBluetoothTransport: NSObject, BLECentralTransport, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var ready: CheckedContinuation<Void, Error>?
    private var scanner: CheckedContinuation<[BLEDiscovery], Error>?
    private var discoveries: [UUID: BLEDiscovery] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connection: CoreBluetoothChannel?
    private var operationID: UUID?
    private var readyTimer: Task<Void, Never>?
    private var scanTimer: Task<Void, Never>?
    private var observed: [UUID:(BLEDiscovery,Date)] = [:]
    func prime(_ discovery: BLEDiscovery, at date: Date) {
        observed = observed.filter { date.timeIntervalSince($0.value.1) < 2 }
        if observed.count < 64 { observed[discovery.id] = (discovery,date) }
    }

    private func begin() throws -> UUID {
        guard operationID == nil, connection == nil else { throw BLETransportFailure.busy }
        let id = UUID(); operationID = id
        return id
    }
    private func manager() async throws -> CBCentralManager {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        guard let central else { throw BLETransportFailure.unavailable }
        if central.state == .unknown || central.state == .resetting {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ready = continuation
                readyTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    self?.completeReady(.failure(BLETransportFailure.timeout))
                }
            }
        }
        guard central.state == .poweredOn else { throw stateFailure(central.state) }
        return central
    }
    func scan(seconds: TimeInterval = 8) async throws -> [BLEDiscovery] {
        let id = try begin()
        defer { if operationID == id { operationID = nil } }
        return try await withTaskCancellationHandler(operation: {
            let manager = try await manager()
            try Task.checkCancellation()
            guard operationID == id else { throw BLETransportFailure.cancelled }
            discoveries.removeAll(); peripherals.removeAll()
            let recent = observed.values.filter { let age = Date().timeIntervalSince($0.1); return age >= 0 && age < 2 }.map(\.0)
            if !recent.isEmpty {
                let known = manager.retrievePeripherals(withIdentifiers:recent.map(\.id))
                for peripheral in known { peripherals[peripheral.identifier] = peripheral }
                let found = recent.filter { peripherals[$0.id] != nil }
                if !found.isEmpty {
                    discoveries = Dictionary(uniqueKeysWithValues:found.map { ($0.id,$0) })
                    return found
                }
            }
            return try await withCheckedThrowingContinuation { continuation in
                scanner = continuation
                manager.scanForPeripherals(withServices: [CBUUID(string: BLECrypto.service)], options: nil)
                let duration = max(1, min(15, seconds.isFinite ? seconds : 8))
                scanTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) } catch { return }
                    guard let self, self.operationID == id else { return }
                    self.finishScan(.success(self.discoveries.values.sorted { $0.rssi > $1.rssi }))
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in if self?.operationID == id { self?.stop() } } })
    }
    func connect(_ discoveryID: UUID, pairing: Bool) async throws -> any BLEChannel {
        let id = try begin()
        do {
            return try await withTaskCancellationHandler(operation: {
                let manager = try await manager()
                try Task.checkCancellation()
                guard operationID == id, let peripheral = peripherals[discoveryID] else { throw BLETransportFailure.cancelled }
                let channel = CoreBluetoothChannel(peripheral: peripheral, pairing: pairing) { [weak self] peripheral in
                    self?.central?.cancelPeripheralConnection(peripheral)
                }
                connection = channel
                manager.connect(peripheral, options: nil)
                try await channel.waitUntilReady()
                try Task.checkCancellation()
                return channel
            }, onCancel: { [weak self] in Task { @MainActor in if self?.operationID == id { self?.stop() } } })
        } catch {
            if operationID == id {
                operationID = nil
                if let connection { connection.fail(error); central?.cancelPeripheralConnection(connection.peripheral) }
            }
            throw error
        }
    }
    func stop() {
        operationID = nil
        completeReady(.failure(BLETransportFailure.cancelled))
        finishScan(.failure(BLETransportFailure.cancelled))
        if let connection {
            connection.fail(BLETransportFailure.cancelled)
            central?.cancelPeripheralConnection(connection.peripheral)
        }
    }
    private func completeReady(_ result: Result<Void, Error>) {
        readyTimer?.cancel(); readyTimer = nil
        let continuation = ready; ready = nil; continuation?.resume(with: result)
    }
    private func finishScan(_ result: Result<[BLEDiscovery], Error>) {
        central?.stopScan(); scanTimer?.cancel(); scanTimer = nil
        let continuation = scanner; scanner = nil; continuation?.resume(with: result)
    }
    private func stateFailure(_ state: CBManagerState) -> Error {
        state == .unauthorized ? BLETransportFailure.denied : BLETransportFailure.unavailable
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { completeReady(.success(())) }
        else if central.state != .unknown && central.state != .resetting {
            let error = stateFailure(central.state)
            completeReady(.failure(error)); finishScan(.failure(error))
            connection?.fail(error)
            // Keep a closing connection until didDisconnect even on power loss;
            // a late disconnect callback must not terminate a later attempt.
            if let connection { central.cancelPeripheralConnection(connection.peripheral) }
            operationID = nil
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanner != nil else { return }
        let bytes = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let payload: Data?
        if let bytes, bytes.count >= 2, UInt16(bytes[bytes.startIndex]) | (UInt16(bytes[bytes.startIndex + 1]) << 8) == BLECrypto.companyID {
            payload = Data(bytes.dropFirst(2))
        } else { payload = nil }
        peripherals[peripheral.identifier] = peripheral
        discoveries[peripheral.identifier] = BLEDiscovery(id: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Контроллер Entrixy",
            rssi: RSSI.intValue, manufacturerPayload: payload)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let connection, connection.peripheral === peripheral, !connection.isClosed else {
            central.cancelPeripheralConnection(peripheral); return
        }
        connection.discover()
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, error: error)
    }
    private func disconnected(_ peripheral: CBPeripheral, error: Error?) {
        guard let connection, connection.peripheral === peripheral else { return }
        connection.didDisconnect(error ?? BLETransportFailure.disconnected)
        self.connection = nil; operationID = nil
    }
}

@MainActor private final class CoreBluetoothChannel: NSObject, BLEChannel, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    let results: AsyncThrowingStream<UInt8, Error>
    private let resultSink: AsyncThrowingStream<UInt8, Error>.Continuation
    private let pairing: Bool
    private let disconnect: (CBPeripheral) -> Void
    private var characteristics: [String: CBCharacteristic] = [:]
    private var selectedService: CBService?
    private var discoveryCount = 0
    private var startup: CheckedContinuation<Void, Error>?
    private var readWaiter: (CBCharacteristic, CheckedContinuation<Data, Error>)?
    private var writeWaiter: (CBCharacteristic, CheckedContinuation<Void, Error>)?
    private var notifyWaiter: (CBCharacteristic, CheckedContinuation<Void, Error>)?
    private var timer: Task<Void, Never>?
    private var startupResult: Result<Void, Error>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeTimer: Task<Void, Never>?
    private(set) var isClosed = false
    private var disconnected = false

    init(peripheral: CBPeripheral, pairing: Bool, disconnect: @escaping (CBPeripheral) -> Void) {
        self.peripheral = peripheral; self.pairing = pairing; self.disconnect = disconnect
        var sink: AsyncThrowingStream<UInt8, Error>.Continuation!
        results = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { sink = $0 }
        resultSink = sink
        super.init()
        peripheral.delegate = self
        armTimeout(seconds: 12)
    }
    func waitUntilReady() async throws {
        if let startupResult { return try startupResult.get() }
        try await withCheckedThrowingContinuation { startup = $0 }
    }
    func discover() { peripheral.discoverServices([CBUUID(string: BLECrypto.service)]) }
    private func armTimeout(seconds: UInt64 = 6) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self else { return }
            self.fail(BLETransportFailure.timeout); self.disconnect(self.peripheral)
        }
    }
    private func idle() throws {
        guard !isClosed, peripheral.state == .connected else { throw BLETransportFailure.disconnected }
        guard readWaiter == nil, writeWaiter == nil, notifyWaiter == nil else { throw BLETransportFailure.busy }
    }
    private func characteristic(_ name: String) throws -> CBCharacteristic {
        guard let value = characteristics[name.lowercased()] else { throw BLETransportFailure.unsupported }
        return value
    }
    func enableResults() async throws -> Bool {
        try idle()
        guard let value = characteristics[BLECrypto.resultCharacteristic.lowercased()] else { return false }
        guard value.properties.contains(.notify) || value.properties.contains(.indicate) else { return false }
        if value.isNotifying { return true }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            notifyWaiter = (value, continuation); armTimeout()
            peripheral.setNotifyValue(true, for: value)
        }
        return true
    }
    func read(_ name: String) async throws -> Data {
        try idle(); let value = try characteristic(name)
        guard value.properties.contains(.read) else { throw BLETransportFailure.unsupported }
        return try await withCheckedThrowingContinuation { continuation in
            readWaiter = (value, continuation); armTimeout(); peripheral.readValue(for: value)
        }
    }
    func write(_ data: Data, to name: String) async throws {
        try idle(); let value = try characteristic(name)
        guard value.properties.contains(.write), !data.isEmpty,
              data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else { throw BLETransportFailure.unsupported }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeWaiter = (value, continuation); armTimeout()
            // Exactly one complete authenticated frame. Never split, downgrade
            // to writeWithoutResponse, or repeat an uncertain write.
            peripheral.writeValue(data, for: value, type: .withResponse)
        }
    }
    func close() async {
        if disconnected { return }
        fail(BLETransportFailure.cancelled); disconnect(peripheral)
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            if closeTimer == nil {
                closeTimer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    self?.finishCloseWaiters()
                }
            }
        }
        // The central still retains this closed channel until didDisconnect.
        // A timeout does not permit an overlapping connection to this object.
    }
    func fail(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true; timer?.cancel(); timer = nil
        if startupResult == nil { startupResult = .failure(error) }
        let startup = self.startup; self.startup = nil
        let read = readWaiter; readWaiter = nil
        let write = writeWaiter; writeWaiter = nil
        let notify = notifyWaiter; notifyWaiter = nil
        startup?.resume(throwing: error); read?.1.resume(throwing: error)
        write?.1.resume(throwing: error); notify?.1.resume(throwing: error)
        resultSink.finish(throwing: error)
    }
    func didDisconnect(_ error: Error) {
        disconnected = true; fail(error); peripheral.delegate = nil; finishCloseWaiters()
    }
    private func finishCloseWaiters() {
        closeTimer?.cancel(); closeTimer = nil
        let pending = closeWaiters; closeWaiters.removeAll(); pending.forEach { $0.resume() }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !isClosed else { return }
        if let error { fail(error); disconnect(peripheral); return }
        let services = peripheral.services?.filter { $0.uuid == CBUUID(string: BLECrypto.service) } ?? []
        guard !services.isEmpty else { fail(BLETransportFailure.unsupported); disconnect(peripheral); return }
        discoveryCount = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !isClosed else { return }
        if let error { fail(error); disconnect(peripheral); return }
        discoveryCount -= 1
        let values = service.characteristics ?? []
        let required = pairing ? [BLECrypto.pairPublicCharacteristic, BLECrypto.pairDoneCharacteristic] : [BLECrypto.nonceCharacteristic, BLECrypto.fireCharacteristic]
        if selectedService == nil, required.allSatisfy({ name in values.contains { $0.uuid == CBUUID(string: name) } }) {
            selectedService = service
            for value in values { characteristics[value.uuid.uuidString.lowercased()] = value }
        }
        guard discoveryCount == 0 else { return }
        guard selectedService != nil else { fail(BLETransportFailure.unsupported); disconnect(peripheral); return }
        timer?.cancel(); timer = nil; startupResult = .success(())
        let continuation = startup; startup = nil; continuation?.resume()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !isClosed, let waiter = notifyWaiter, waiter.0 === characteristic else { return }
        notifyWaiter = nil; timer?.cancel(); timer = nil
        if let error { waiter.1.resume(throwing: error) }
        else if !characteristic.isNotifying { waiter.1.resume(throwing: BLETransportFailure.unsupported) }
        else { waiter.1.resume() }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !isClosed else { return }
        if characteristic === characteristics[BLECrypto.resultCharacteristic.lowercased()] {
            if let error { fail(error); disconnect(peripheral) }
            else if let bytes = characteristic.value, bytes.count == 1 { resultSink.yield(bytes[bytes.startIndex]) }
            return
        }
        guard let waiter = readWaiter, waiter.0 === characteristic else { return }
        readWaiter = nil; timer?.cancel(); timer = nil
        if let error { waiter.1.resume(throwing: error) }
        else if let bytes = characteristic.value { waiter.1.resume(returning: bytes) }
        else { waiter.1.resume(throwing: BLETransportFailure.invalidValue) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !isClosed, let waiter = writeWaiter, waiter.0 === characteristic else { return }
        writeWaiter = nil; timer?.cancel(); timer = nil
        if let error { waiter.1.resume(throwing: error) } else { waiter.1.resume() }
    }
}
