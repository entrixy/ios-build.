import XCTest
@testable import EntrixyCore

final class BLEDeviceInformationTests: XCTestCase {
    private func fixture() throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:Data(contentsOf:Bundle.module.url(forResource:"ble-v1",withExtension:"json",subdirectory:"Fixtures")!)) as! [String:Any]
    }
    private func bytes(_ values: [String:Any],_ key: String) -> Data { Data(base64Encoded:values[key] as! String)! }
    func testIndependentFirmwareVectorsExposeOwnerTelemetryWithExactVersionNibbles() throws {
        let f = try fixture(), date = Date(timeIntervalSince1970:1700000000)
        for name in ["adv_v3","adv_state"] {
            let info = try BLEDeviceInformation(payload:bytes(f,name),ownerSecret:bytes(f,"owner_secret"),observedAt:date)
            XCTAssertEqual(info.deviceID,0x89abcdef); XCTAssertEqual(info.batteryPercent,87)
            XCTAssertEqual(info.statusFlags,0x21); XCTAssertEqual(info.firmwareMajor,10); XCTAssertEqual(info.firmwareMinor,9)
            XCTAssertEqual(info.hardwareModel,3); XCTAssertEqual(info.observedAt,date)
        }
    }
    func testLegacyAdvertisementsCannotBeTurnedIntoZeroBatteryOrInventedFirmware() throws {
        let f = try fixture()
        for name in ["adv_v1","adv_v2"] {
            XCTAssertThrowsError(try BLEDeviceInformation(payload:bytes(f,name),ownerSecret:bytes(f,"owner_secret")))
        }
    }
    func testWrongOwnerOrModifiedEncryptedMetadataCannotPopulateInformation() throws {
        let f = try fixture(); var payload = bytes(f,"adv_v3")
        XCTAssertThrowsError(try BLEDeviceInformation(payload:payload,ownerSecret:Data(repeating:0,count:32)))
        payload[17] ^= 1
        XCTAssertThrowsError(try BLEDeviceInformation(payload:payload,ownerSecret:bytes(f,"owner_secret")))
    }
}
