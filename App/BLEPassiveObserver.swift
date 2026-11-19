import Foundation
import CoreBluetooth
import EntrixyCore

/// Service-filtered observation only: this central never connects or writes.
@MainActor final class BLEPassiveObserver: NSObject, @preconcurrency CBCentralManagerDelegate {
    var onAdvertisement: ((Data,Int) -> Void)?
    var onDiscovery: ((BLEDiscovery) -> Void)?
    private var central: CBCentralManager?
    private var enabled = false
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value, central == nil {
            central = CBCentralManager(delegate:self,queue:.main,options:[
                CBCentralManagerOptionShowPowerAlertKey:false,
                CBCentralManagerOptionRestoreIdentifierKey:"com.entrixy.ios.automation-observer"])
        }
        updateScan()
    }
    private func updateScan() {
        guard let central, central.state == .poweredOn else { return }
        if enabled { central.scanForPeripherals(withServices:[CBUUID(string:BLECrypto.service)],options:[CBCentralManagerScanOptionAllowDuplicatesKey:true]) }
        else { central.stopScan() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateScan() }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String:Any]) {
        // This observer never connects/writes. Resume only its filtered scan;
        // a restored radio session is not fresh authenticated proximity.
        updateScan()
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        guard enabled, let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2,
              UInt16(data[data.startIndex]) | UInt16(data[data.startIndex+1]) << 8 == BLECrypto.companyID else { return }
        let payload = Data(data.dropFirst(2))
        if let onDiscovery {
            onDiscovery(BLEDiscovery(id:peripheral.identifier,name:peripheral.name ?? "Entrixy",rssi:RSSI.intValue,manufacturerPayload:payload))
        } else { onAdvertisement?(payload,RSSI.intValue) }
    }
}
