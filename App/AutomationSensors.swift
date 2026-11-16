import Foundation
import Combine
import CoreLocation
import NetworkExtension

struct AutomationWiFiNetwork: Equatable {
    let ssid: String
    let bssid: String
}

@MainActor final class AutomationSensors: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var network: AutomationWiFiNetwork?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var locating = false
    @Published private(set) var message: String?
    var onLocation: ((CLLocation) -> Void)?
    // Core Location delivers delegate callbacks on the initializing main run loop.
    private let manager = CLLocationManager()
    private var requests: [CheckedContinuation<CLLocation, Error>] = []
    private var requestTimeout: Task<Void, Never>?
    private var tracking = false

    override init() {
        super.init()
        manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5; locationAuthorization = manager.authorizationStatus
    }

    func currentLocation() async throws -> CLLocation {
        if let location, abs(location.timestamp.timeIntervalSinceNow) < 10,
           location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 { return location }
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation); locating = true; message = nil
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
            default: finishLocation(.failure(CLError(.denied)))
            }
            guard !requests.isEmpty, requestTimeout == nil else { return }
            requestTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                self?.finishLocation(.failure(CLError(.locationUnknown)))
            }
        }
    }

    func refreshNetwork() {
        NEHotspotNetwork.fetchCurrent { [weak self] value in
            Task { @MainActor in
                self?.network = value.map { AutomationWiFiNetwork(ssid: $0.ssid, bssid: $0.bssid.lowercased()) }
            }
        }
    }

    func trackLocation(enabled: Bool, background: Bool) {
        tracking = enabled
        if !enabled { manager.stopUpdatingLocation(); manager.stopMonitoringSignificantLocationChanges(); return }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.allowsBackgroundLocationUpdates = background && manager.authorizationStatus == .authorizedAlways
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
        if manager.authorizationStatus == .authorizedAlways { manager.startMonitoringSignificantLocationChanges() }
    }

    func requestBackgroundLocation() {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        else if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorization = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if !requests.isEmpty { manager.requestLocation() }
            if tracking { trackLocation(enabled: true, background: true) }
            refreshNetwork()
        case .denied, .restricted: finishLocation(.failure(CLError(.denied)))
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last(where: { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 30 }) else { return }
        location = latest
        if latest.horizontalAccuracy <= 100 { finishLocation(.success(latest)) }
        onLocation?(latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(.failure(error))
    }

    private func finishLocation(_ result: Result<CLLocation, Error>) {
        let pending = requests; requests.removeAll(); locating = false
        requestTimeout?.cancel(); requestTimeout = nil
        if case .failure = result { message = ProductText.string("action_gps_timeout") }
        for request in pending { request.resume(with: result) }
    }
}
