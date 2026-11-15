import Foundation
import EntrixyCore

/// Frozen object, policy and direction for one manual tap, rechecked after authentication.
struct OwnerActionIntent: Identifiable {
    let id = UUID()
    let server: String
    let object: OwnerObject
    let label: String
    let action: GuestAction
    let policy: OwnerManualPolicy
    let created = ProcessInfo.processInfo.systemUptime
    var title: String {
        object.kind == "call" ? "Позвонить" : ActionIntent.displayTitle(action: action, kind: object.kind)
    }
}
