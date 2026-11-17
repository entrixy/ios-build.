import Foundation

public struct OwnerAuthorizedGuest {
    public let id: UUID
    public let label: String
    public let publicKey: Data
    public var company: CompanyGrant? = nil
    public var serverKeyID: Int? = nil
    public var numberIDs: [Int] = []

    public func verifyPress(_ press: [String:Any], server: String, numberID: Int, expectedAction: String,
                            now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> (nonce: String, actor: String?) {
        if let company, let serverKeyID, let pinned = company.publicKey {
            let proof = try CompanyPress.verify(press,publicKey:pinned,keyID:serverKeyID,numberID:numberID,numberIDs:numberIDs,expectedAction:expectedAction,now:now)
            return ("o:" + proof.nonce,proof.actor)
        }
        guard company == nil, press["org"] == nil, press["action"] as? String == expectedAction else { throw GuestCrypto.Failure.invalidKey }
        return (try OwnerGuestPress.verify(press,publicKey:publicKey,server:server,numberID:numberID,now:now),nil)
    }
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
            if let company = root.company {
                guard let pinned = company.publicKey, pinned.count == 32,
                      objects?.contains(where:{ $0.numberID == numberID && $0.kind == "call" }) == true else { return nil }
                return OwnerAuthorizedGuest(id:root.id,label:root.label,publicKey:pinned,company:company,serverKeyID:root.keyID,numberIDs:root.effectiveNumberIDs ?? root.numberIDs)
            }
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
