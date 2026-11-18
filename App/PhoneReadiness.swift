import SwiftUI
import CoreBluetooth
import CoreLocation
import UserNotifications
import EntrixyCore

/// Reading readiness never creates a Bluetooth manager or asks for permission.
@MainActor final class PhoneReadiness: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published private(set) var bluetooth = PhonePermissionState.Access.unknown
    @Published private(set) var notifications = PhonePermissionState.Access.unknown
    private var permissionCentral: CBCentralManager?
    private func bluetoothAccess() -> PhonePermissionState.Access {
        switch CBManager.authorization { case .allowedAlways: return .allowed; case .notDetermined: return .unknown; default: return .denied }
    }
    func refresh() async {
        bluetooth = bluetoothAccess()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized,.provisional,.ephemeral: notifications = .allowed
        case .notDetermined: notifications = .unknown
        default: notifications = .denied
        }
    }
    func state(_ sensors: AutomationSensors) -> PhonePermissionState {
        let location: PhonePermissionState.Location
        switch sensors.locationAuthorization {
        case .authorizedAlways: location = .always
        case .authorizedWhenInUse: location = .whenInUse
        case .notDetermined: location = .unknown
        default: location = .denied
        }
        return PhonePermissionState(location:location,precise:sensors.preciseLocationAuthorized,bluetooth:bluetooth,notifications:notifications)
    }
    func opensSettings(_ issue: PhonePermissionState.Issue,sensors: AutomationSensors) -> Bool {
        switch issue {
        case .location: return sensors.locationAuthorization != .notDetermined
        case .preciseLocation: return true
        case .backgroundLocation: return sensors.locationAuthorization != .authorizedWhenInUse
        case .bluetooth: return bluetoothAccess() != .unknown
        case .notifications: return notifications != .unknown
        }
    }
    func request(_ issue: PhonePermissionState.Issue,sensors: AutomationSensors) async {
        if opensSettings(issue,sensors:sensors) {
            if let url = URL(string:UIApplication.openSettingsURLString) { _ = await UIApplication.shared.open(url) }
            return
        }
        switch issue {
        case .location: sensors.requestNetworkAccess()
        case .backgroundLocation: sensors.requestBackgroundLocation()
        case .bluetooth:
            if permissionCentral == nil { permissionCentral = CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false]) }
        case .notifications: _ = await OwnerPhoneNotifications.authorize()
        case .preciseLocation: break
        }
        await refresh()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { bluetooth = bluetoothAccess() }
}

struct PhoneReadinessCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @ObservedObject var service: PhoneReadiness
    @ObservedObject var sensors: AutomationSensors
    private var missing: [PhonePermissionState.Issue] { service.state(sensors).missing(model.phoneRequirements()) }
    var body: some View {
        Group {
            if let first = missing.first {
                VStack(alignment:.leading,spacing:12) {
                    Label(ProductText.string("perm_card_need"),systemImage:"exclamationmark.triangle").font(.headline).accessibilityIdentifier("phone-readiness-card")
                    ForEach(missing) { issue in Text("• " + ProductText.string("ios_perm_"+issue.rawValue)).font(.subheadline) }
                    Button(ProductText.string(service.opensSettings(first,sensors:sensors) ? "ios_perm_settings" : "ios_perm_allow")) {
                        Task { await service.request(first,sensors:sensors) }
                    }.buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("phone-readiness-action")
                }.foregroundStyle(Brand.ink).padding(16)
                    .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
                    .padding(.horizontal,20).padding(.top,12)
            }
        }.task { await service.refresh() }
            .onChange(of:phase) { if $0 == .active { Task { await service.refresh() } } }
    }
}
