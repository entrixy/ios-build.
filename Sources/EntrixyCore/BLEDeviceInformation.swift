import Foundation

/// Owner-only telemetry from Android BleCrypto's authenticated, encrypted v3/v4
/// advertise fields. This is information for display, never action authority.
public struct BLEDeviceInformation: Equatable {
    public let deviceID: UInt32
    public let batteryPercent: UInt8
    public let statusFlags: UInt8
    public let firmwareMajor: UInt8
    public let firmwareMinor: UInt8
    public let hardwareModel: UInt8
    public let sleepSeconds: UInt8?
    public let observedAt: Date
    public init(payload: Data, ownerSecret: Data, observedAt: Date = Date()) throws {
        let value = try BLECrypto.verifyAdvertisement(payload,ownerSecret:ownerSecret)
        guard let battery = value.battery, battery <= 100, let flags = value.status,
              let firmware = value.firmware, let hardware = value.hardware,
              observedAt.timeIntervalSince1970.isFinite else { throw GuestCrypto.Failure.invalidEnvelope }
        deviceID = value.deviceID; batteryPercent = battery; statusFlags = flags
        firmwareMajor = firmware >> 4; firmwareMinor = firmware & 15; hardwareModel = hardware
        sleepSeconds = value.sleepSeconds; self.observedAt = observedAt
    }
}
