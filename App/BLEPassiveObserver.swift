import Foundation
import CoreBluetooth
import EntrixyCore

/// Service-filtered observation only: this central never connects or writes.
@MainActor final class BLEPassiveObserver: NSObject, @preconcurrency CBCentralManagerDelegate {
    var onAdvertisement: ((Data,Int) -> Void)?
    private var central: CBCentralManager?
    private var enabled = false
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value, central == nil {
            central = CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
        }
        updateScan()
    }
    private func updateScan() {
        guard let central, central.state == .poweredOn else { return }
        if enabled { central.scanForPeripherals(withServices:[CBUUID(string:BLECrypto.service)],options:[CBCentralManagerScanOptionAllowDuplicatesKey:true]) }
        else { central.stopScan() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateScan() }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        guard enabled, let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2,
              UInt16(data[data.startIndex]) | UInt16(data[data.startIndex+1]) << 8 == BLECrypto.companyID else { return }
        onAdvertisement?(Data(data.dropFirst(2)),RSSI.intValue)
    }
}
