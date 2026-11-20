import Foundation
import EntrixyCore

enum CatalogAvailability { case ready, offline, connecting, neutral, unknown }

enum CatalogObject: Identifiable {
    case owned(OwnerAccount, OwnerObject)
    case received(SavedGuest, GuestObject)
    var target: ObjectReference {
        switch self {
        case let .owned(owner, object): return .owned(server: owner.server, objectID: object.id)
        case let .received(guest, object): return .received(guestID: guest.id, objectID: object.id)
        }
    }
    var id: ObjectReference { target }
    var kind: String {
        switch self { case let .owned(_, object): return object.kind; case let .received(_, object): return object.kind }
    }
    var sourceLabel: String { switch self { case .owned: return ProductText.string("source_mine"); case .received: return ProductText.string("action_source_guest") } }
    var originalLabel: String {
        switch self {
        case let .owned(owner, object): return (try? object.metadata(masterKey: owner.masterKey)["label"] as? String) ?? "Название недоступно"
        case let .received(_, object): return object.label
        }
    }
    var canControl: Bool {
        switch self { case let .owned(owner, object): return owner.ownershipLost != true && object.ownerCardAvailable; case .received: return true }
    }
}

extension AppModel {
    /// Both roots consume the same ordering and visibility. Sync keeps all owner
    /// and received objects; local hiding never deletes credentials or siblings.
    func catalogObjects(includeHidden: Bool = false) -> [CatalogObject] {
        let owned = owners.flatMap { owner in (owner.objects ?? []).map { CatalogObject.owned(owner, $0) } }
        let incoming = guests.flatMap { guest in guest.objects.map { CatalogObject.received(guest, $0) } }
        return objectPreferences.sorted(owned + incoming, reference: \.target).filter {
            includeHidden || !objectPreferences.presentation(for: $0.target).hidden
        }
    }
    var controlObjects: [CatalogObject] { catalogObjects().filter(\.canControl) }
    func catalogObject(_ target: ObjectReference) -> CatalogObject? { catalogObjects().first { $0.target == target } }
    func objectLabel(_ entry: CatalogObject) -> String { objectPreferences.presentation(for: entry.target).label ?? entry.originalLabel }
    func objectIsVisible(_ target: ObjectReference) -> Bool { !objectPreferences.presentation(for: target).hidden }

    @discardableResult func renameReceivedObject(_ target: ObjectReference, label: String) -> Bool {
        guard case .received = target, catalogObject(target) != nil else { return false }
        do {
            var preferences = objectPreferences; try preferences.rename(target, label: label)
            return saveObjectPreferences(preferences)
        } catch { errorMessage = "Название слишком длинное. Используйте до 64 символов."; return false }
    }
    @discardableResult func hideReceivedObject(_ target: ObjectReference) -> Bool {
        guard case .received = target, catalogObject(target) != nil else { return false }
        do {
            var preferences = objectPreferences; try preferences.hide(target)
            return saveObjectPreferences(preferences)
        } catch { errorMessage = "Не удалось скрыть объект."; return false }
    }
    func reorderObjects(_ targets: [ObjectReference]) {
        let subset = Set(targets)
        let all = catalogObjects(includeHidden: true).map(\.target)
        guard subset.count == targets.count, Set(all).count == all.count,
              subset.isSubset(of: Set(catalogObjects().map(\.target))) else { return }
        var replacements = targets.makeIterator()
        var preferences = objectPreferences
        let ordered = all.map { subset.contains($0) ? replacements.next()! : $0 }
        let known = Set(ordered)
        preferences.order = ordered + preferences.order.filter { !known.contains($0) }
        saveObjectPreferences(preferences)
    }
}
