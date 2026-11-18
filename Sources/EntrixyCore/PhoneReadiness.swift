import Foundation

public struct PhoneRequirements: Equatable {
    public var location = false
    public var preciseLocation = false
    public var backgroundLocation = false
    public var bluetooth = false
    public var notifications = false
    public init() {}
}
public struct PhonePermissionState: Equatable {
    public enum Access: Equatable { case unknown, denied, allowed }
    public enum Location: Equatable { case unknown, denied, whenInUse, always }
    public var location: Location
    public var precise: Bool
    public var bluetooth: Access
    public var notifications: Access
    public init(location: Location,precise: Bool,bluetooth: Access,notifications: Access) {
        self.location = location; self.precise = precise; self.bluetooth = bluetooth; self.notifications = notifications
    }
    public enum Issue: String, CaseIterable, Identifiable {
        case location, preciseLocation, backgroundLocation, bluetooth, notifications
        public var id: String { rawValue }
    }
    public func missing(_ needs: PhoneRequirements) -> [Issue] {
        var result: [Issue] = []
        if needs.location {
            if location == .unknown || location == .denied { result.append(.location) }
            else {
                if needs.preciseLocation && !precise { result.append(.preciseLocation) }
                if needs.backgroundLocation && location != .always { result.append(.backgroundLocation) }
            }
        }
        if needs.bluetooth && bluetooth != .allowed { result.append(.bluetooth) }
        if needs.notifications && notifications != .allowed { result.append(.notifications) }
        return result
    }
}
