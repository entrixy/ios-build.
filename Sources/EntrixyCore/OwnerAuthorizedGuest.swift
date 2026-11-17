import Foundation

public struct OwnerAuthorizedGuest {
    public let id: UUID
    public let label: String
    public let publicKey: Data
}
public extension OwnerAccount {
    func authorizedGuest(keyID: Int, numberID: Int) throws -> OwnerAuthorizedGuest? {
        if let root = issuedKeys?.first(where: { $0.keyID == keyID }) { return try authorizedGuest(localID: root.id, numberID: numberID) }
        if let leaf = delegatedKeys?.first(where: { $0.keyID == keyID && $0.state == .ready }) { return try authorizedGuest(localID: leaf.id, numberID: numberID) }
        return nil
    }
    func authorizedGuest(localID: UUID, numberID: Int) throws -> OwnerAuthorizedGuest? {
        func rootAllowed(_ key: OwnerIssuedKey) -> Bool {
            key.pending == nil && (key.state == .active || key.state == .restricted)
                && (key.effectiveNumberIDs ?? key.numberIDs).contains(numberID)
        }
        if let root = issuedKeys?.first(where: { $0.id == localID }), rootAllowed(root) {
            let pair = try root.secrets(masterKey: masterKey)
            return OwnerAuthorizedGuest(id: root.id, label: root.label,
                publicKey: try GuestCrypto.signingKey(userKey: pair.userKey).publicKey.rawRepresentation)
        }
        guard let leaf = delegatedKeys?.first(where: { $0.id == localID && $0.state == .ready && $0.revocationPending != true }),
              leaf.confirmedNumberIDs.contains(numberID) else { return nil }
        var parentID = leaf.parentKeyID, visited: Set<Int> = [leaf.keyID]
        for level in 1...5 {
            guard visited.insert(parentID).inserted else { return nil }
            if let root = issuedKeys?.first(where: { $0.keyID == parentID && $0.id == leaf.rootID }) {
                guard rootAllowed(root), let local = root.grantedAccess?[String(numberID)],
                      let effective = root.access?[String(numberID)], min(local.depth, effective.depth) >= level else { return nil }
                return OwnerAuthorizedGuest(id: leaf.id, label: leaf.label, publicKey: try GuestCrypto.decodeBase64URL(leaf.signPublic))
            }
            guard let parent = delegatedKeys?.first(where: { $0.keyID == parentID && $0.rootID == leaf.rootID && $0.state == .ready && $0.revocationPending != true }),
                  parent.confirmedNumberIDs.contains(numberID), (parent.access[String(numberID)]?.depth ?? 0) >= level else { return nil }
            parentID = parent.parentKeyID
        }
        return nil
    }
    func callPreference(guestID: UUID, numberID: Int) -> OwnerCallPreference? {
        let rootID = issuedKeys?.first(where: { $0.id == guestID })?.id
            ?? delegatedKeys?.first(where: { $0.id == guestID })?.rootID
        return issuedKeys?.first(where: { $0.id == rootID })?.callPreferences?[String(numberID)]
    }

}
