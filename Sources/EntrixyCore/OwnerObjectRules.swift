import Foundation

public extension OwnerIssuedKey {
    mutating func configureObjectSettings(numberID: Int, template: AutomationTemplate,
                                         allowStream: Bool, masterKey: Data) throws {
        guard numberIDs.contains(numberID), state == .active || state == .paused else { throw GuestCrypto.Failure.invalidEnvelope }
        let encoded = try template.data()
        let contents = try bundle(masterKey: masterKey)
        var templates = automationTemplates ?? [:]; templates[String(numberID)] = encoded
        var streams = Set(streamAllowed ?? contents["streams"] as? [Int] ?? numberIDs)
        if allowStream { streams.insert(numberID) } else { streams.remove(numberID) }
        // Editing rules while an earlier bundle is in flight changes only the
        // local source. Its already persisted request/cipher is left intact.
        automationTemplates = templates; streamAllowed = streams.sorted()
    }
    func objectTemplate(numberID: Int, owner: OwnerAccount) throws -> AutomationTemplate {
        guard numberIDs.contains(numberID) else { throw GuestCrypto.Failure.invalidEnvelope }
        if let data = automationTemplates?[String(numberID)] { return try AutomationTemplate(data: data) }
        let contents = try bundle(masterKey: owner.masterKey)
        let ble = (contents["ble"] as? [[String: Any]])?.first { ($0["id"] as? Int) == numberID }
        let row = ble?["tpl"] as? [String: Any] ?? (contents["templates"] as? [String: [String: Any]])?[String(numberID)] ?? [:]
        return try AutomationTemplate(data: JSONSerialization.data(withJSONObject: row))
    }

    mutating func setObjectRules(owner: OwnerAccount, numberID: Int, template: AutomationTemplate,
                                 allowStream: Bool) throws {
        guard numberIDs.contains(numberID) else { throw GuestCrypto.Failure.invalidEnvelope }
        let contents = try bundle(masterKey: owner.masterKey)
        var draft = self
        var templates = automationTemplates ?? [:]; templates[String(numberID)] = try template.data()
        draft.automationTemplates = templates
        var streams = Set(streamAllowed ?? contents["streams"] as? [Int] ?? numberIDs)
        if allowStream { streams.insert(numberID) } else { streams.remove(numberID) }
        draft.streamAllowed = streams.sorted()
        try draft.edit(owner: owner, label: label, numberIDs: numberIDs,
            welcome: contents["welcome"] as? String ?? "", confirmation: nil)
        self = draft
    }

    mutating func refreshObjectSettings(owner: OwnerAccount) throws {
        let contents = try bundle(masterKey: owner.masterKey)
        try edit(owner: owner, label: label, numberIDs: numberIDs,
            welcome: contents["welcome"] as? String ?? "", confirmation: nil)
    }
}

public extension OwnerAccount {
    mutating func setPrivacyNetworks(_ networks: [PrivacyNetwork]) throws {
        try PrivacyNetwork.validate(networks)
        guard privacyNetworks != networks else { return }
        privacyNetworks = networks
        for key in issuedKeys ?? [] where key.state != .revoked { queueKeySettings(key.id) }
    }
    mutating func queueObjectSettings(numberID: Int) {
        var queue = bundleRefreshQueue ?? [:]
        for key in issuedKeys ?? [] where key.numberIDs.contains(numberID) && key.state != .revoked {
            queue[key.id.uuidString] = UUID().uuidString
        }
        bundleRefreshQueue = queue
    }
    mutating func queueKeySettings(_ id: UUID) {
        guard (issuedKeys ?? []).contains(where: { $0.id == id && $0.state != .revoked }) else { return }
        var queue = bundleRefreshQueue ?? [:]; queue[id.uuidString] = UUID().uuidString; bundleRefreshQueue = queue
    }
}
