import Foundation
import EntrixyCore

enum AutomationDestination: Identifiable, Hashable {
    case object(ObjectReference)
    case issued(server: String, keyID: UUID, objectID: UUID)
    var id: String {
        switch self {
        case .object(let target): return "object:" + target.id
        case .issued(let server, let key, let object): return "issued:" + server + ":" + key.uuidString + ":" + object.uuidString
        }
    }
}

struct AutomationSettingsContext {
    let destination: AutomationDestination
    let label: String
    let isBLE: Bool
    let incoming: Bool
    let issued: Bool
    let template: AutomationTemplate
    let ownerTemplate: AutomationTemplate?
    let objectTemplate: AutomationTemplate?
    let allowStream: Bool
    let canEdit: Bool
}

extension AppModel {
    func automationContext(_ destination: AutomationDestination) throws -> AutomationSettingsContext {
        switch destination {
        case .object(.owned(let server, let id)):
            guard let owner = owners.first(where: { $0.server == server }),
                  let object = owner.objects?.first(where: { $0.id == id }) else { throw GuestCrypto.Failure.invalidEnvelope }
            return AutomationSettingsContext(destination: destination,
                label: try object.metadata(masterKey: owner.masterKey)["label"] as? String ?? "",
                isBLE: object.kind == "ble", incoming: false, issued: false,
                template: try AutomationTemplate(data: object.localPolicy), ownerTemplate: nil, objectTemplate: nil,
                allowStream: false, canEdit: canManageGuestAccess && object.pending != .delete)
        case .object(.received(let guestID, let objectID)):
            guard let guest = guests.first(where: { $0.id == guestID }),
                  let object = guest.objects.first(where: { $0.id == objectID }) else { throw GuestCrypto.Failure.invalidEnvelope }
            let rules = guest.automation?[objectID] ?? IncomingAutomationConfiguration(owner: AutomationTemplate())
            return AutomationSettingsContext(destination: destination,
                label: objectLabel(.received(guest, object)), isBLE: object.kind == "ble", incoming: true, issued: false,
                template: rules.effective, ownerTemplate: rules.owner, objectTemplate: nil,
                allowStream: guest.cameras?[objectID] != nil, canEdit: canManageGuestAccess)
        case .issued(let server, let keyID, let objectID):
            guard let owner = owners.first(where: { $0.server == server }),
                  let key = owner.issuedKeys?.first(where: { $0.id == keyID }),
                  let object = owner.objects?.first(where: { $0.id == objectID }),
                  let number = object.numberID, key.numberIDs.contains(number) else { throw GuestCrypto.Failure.invalidEnvelope }
            let bundle = try key.bundle(masterKey: owner.masterKey)
            return AutomationSettingsContext(destination: destination,
                label: try object.metadata(masterKey: owner.masterKey)["label"] as? String ?? "",
                isBLE: object.kind == "ble", incoming: false, issued: true,
                template: try key.objectTemplate(numberID: number, owner: owner), ownerTemplate: nil,
                objectTemplate: try AutomationTemplate(data: object.localPolicy),
                allowStream: (key.streamAllowed ?? bundle["streams"] as? [Int] ?? key.numberIDs).contains(number),
                canEdit: canManageGuestAccess && [.active, .paused].contains(key.state) && key.pending != .keyRevoke)
        }
    }
}
