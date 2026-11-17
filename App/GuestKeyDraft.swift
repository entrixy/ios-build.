import Foundation
import Combine
import EntrixyCore

@MainActor final class GuestKeyDraft: ObservableObject {
    let id = UUID()
    @Published var selected = Set<Int>()
    @Published var access: [Int: KeyObjectAccess] = [:]
    @Published var templates: [Int: AutomationTemplate] = [:]
    @Published var streams: [Int: Bool] = [:]
    @Published var lifetimes: [Int: UInt32] = [:]
    @Published var calls: [Int: OwnerCallPreference] = [:]
    var editingKeyID: UUID?
    func load(owner: OwnerAccount, key: OwnerIssuedKey) throws {
        editingKeyID = key.id; selected = Set(key.effectiveNumberIDs ?? key.numberIDs)
        access = Dictionary(uniqueKeysWithValues: (key.access ?? key.grantedAccess ?? [:]).compactMap { name, value in Int(name).map { ($0,value) } })
        let bundle = try key.bundle(masterKey: owner.masterKey)
        let allowed = key.streamAllowed ?? bundle["streams"] as? [Int] ?? key.numberIDs
        for object in owner.objects ?? [] {
            guard let number = object.numberID else { continue }
            if key.numberIDs.contains(number) { templates[number] = try key.objectTemplate(numberID: number, owner: owner) }
            streams[number] = key.numberIDs.contains(number) ? allowed.contains(number) : true
            lifetimes[number] = key.bleTokenLifetimes?[String(number)] ?? BLETokenLifetime.defaultValue
            calls[number] = key.callPreferences?[String(number)] ?? OwnerCallPreference()
        }
    }
    func configuration(owner: OwnerAccount) throws -> OwnerKeyConfiguration {
        var result = OwnerKeyConfiguration()
        for number in selected { result.automation[String(number)] = try (templates[number] ?? AutomationTemplate()).data() }
        result.streams = selected.filter { id in (streams[id] ?? true) && (owner.objects ?? []).contains(where: { $0.numberID == id && $0.kind != "ble" }) }.sorted()
        result.bleLifetimes = Dictionary(uniqueKeysWithValues: selected.compactMap { id in
            (owner.objects ?? []).contains(where: { $0.numberID == id && $0.kind == "ble" }) ? (String(id), lifetimes[id] ?? BLETokenLifetime.defaultValue) : nil
        })
        result.calls = Dictionary(uniqueKeysWithValues: selected.compactMap { id in
            (owner.objects ?? []).contains(where: { $0.numberID == id && $0.kind == "call" }) ? (String(id), calls[id] ?? OwnerCallPreference()) : nil
        })
        try result.validate(numberIDs: Array(selected))
        return result
    }
    func syncSavedSettings(owner: OwnerAccount) {
        guard let key = owner.issuedKeys?.first(where: { $0.id == editingKeyID }) else { return }
        for id in selected where key.numberIDs.contains(id) {
            if let value = try? key.objectTemplate(numberID: id, owner: owner) { templates[id] = value }
            lifetimes[id] = key.bleTokenLifetimes?[String(id)] ?? BLETokenLifetime.defaultValue
            calls[id] = key.callPreferences?[String(id)] ?? OwnerCallPreference()
        }
    }
}
