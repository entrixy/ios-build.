import SwiftUI
import CoreLocation
import EntrixyCore

struct KeyAcceptance: Identifiable {
    let id = UUID()
    let guestID: String
}

extension AppModel {
    func presentKeyAcceptance(_ id: String) {
        guard canManageGuestAccess, let guest = guests.first(where:{ $0.id == id }), guest.checkedAt != nil else { return }
        keyAcceptance = KeyAcceptance(guestID:id)
    }
}

/// MainActivity keyJustAdded: readiness from THIS key's effective rules and
/// welcome from its authenticated encrypted bundle, dismissible only by OK.
struct KeyAcceptanceDialog: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var sensors: AutomationSensors
    let presentation: KeyAcceptance
    private var guest: SavedGuest? { model.guests.first { $0.id == presentation.guestID } }
    private var rules: [AutomationTemplate] { guest?.automation?.values.map(\.effective) ?? [] }
    private var needsGeo: Bool { rules.contains { $0.geoEnabled } }
    private var needsWiFi: Bool { rules.contains { $0.wifiEnabled } }
    private var locationAllowed: Bool { [.authorizedAlways,.authorizedWhenInUse].contains(sensors.locationAuthorization) }
    var body: some View {
        AppDialogSurface {
            VStack(alignment:.leading,spacing:18) {
                Text(ProductText.string("key_added_title")).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("key-accepted-title")
                if needsGeo || needsWiFi {
                    Text(ProductText.string("key_added_ready_head")).font(.subheadline.weight(.semibold))
                    if needsWiFi { check("ready_wifi",ready:sensors.network != nil ? true : (locationAllowed ? false : nil)) }
                    if needsGeo {
                        check("ready_location_gps",ready:CLLocationManager.locationServicesEnabled())
                        check("ready_location_perm",ready:locationAllowed)
                    }
                } else { Text(ProductText.string("key_added_body")) }
                if let welcome = guest?.welcome,!welcome.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Text(ProductText.string("owner_says_label")).font(.subheadline.bold())
                        Text(linkified(welcome)).textSelection(.enabled).privacySensitive()
                            .accessibilityIdentifier("key-owner-welcome")
                    }
                }
                Button(ProductText.string("btn_ok")) { model.keyAcceptance = nil }
                    .buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("key-accepted-ok")
            }.foregroundStyle(Brand.ink)
        }.task { if needsWiFi { sensors.refreshNetwork() } }
    }
    private func check(_ key: String, ready: Bool?) -> some View {
        HStack(spacing:10) {
            Image(systemName:ready == true ? "checkmark.circle.fill" : ready == false ? "xmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(ready == true ? Color.green : ready == false ? AppPalette.destructive : Brand.secondaryInk)
            Text(ProductText.string(key)).font(.subheadline)
        }
    }
    private func linkified(_ value: String) -> AttributedString {
        var result = AttributedString()
        var cursor = value.startIndex
        guard let detector = try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue) else { return AttributedString(value) }
        for match in detector.matches(in:value,range:NSRange(value.startIndex...,in:value)) {
            guard let url = match.url,["https","http","mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range,in:value),range.lowerBound >= cursor else { continue }
            result += AttributedString(String(value[cursor..<range.lowerBound]))
            var link = AttributedString(String(value[range])); link.link = url; result += link
            cursor = range.upperBound
        }
        result += AttributedString(String(value[cursor...]))
        return result
    }
}
