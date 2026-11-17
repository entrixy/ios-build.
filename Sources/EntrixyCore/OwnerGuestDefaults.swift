import Foundation

/// Android Guests/Presets: only NEW object selections use this access default.
/// Changing it never rewrites an already-issued guest's authority.
public struct OwnerGuestDefaults: Codable, Equatable {
    public var ownerName = ""
    public var access = try! KeyObjectAccess()
    public init() {}
    public func validate() throws {
        guard ownerName.count <= 40, !ownerName.contains("\n"), !ownerName.contains("\r") else { throw GuestCrypto.Failure.invalidEnvelope }
        try access.validate()
    }
}

public extension OwnerIssuedKey {
    /// Explicit clone: new signing/bundle key and controller DID from the FIRST
    /// request, with the source key's narrowed settings. No original token is
    /// temporarily installed on the clone.
    func cloned(owner: OwnerAccount, label: String) throws -> Self {
        guard company == nil, owner.issuedKeys?.contains(self) == true, pending == nil, keyID != nil, [.active,.paused,.restricted].contains(state), accessNeedsReview != true else { throw GuestCrypto.Failure.invalidEnvelope }
        let ids = effectiveNumberIDs ?? numberIDs
        guard !ids.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        let rights = try Dictionary(uniqueKeysWithValues:ids.map { number -> (Int,KeyObjectAccess) in
            let name = String(number), fallback = try KeyObjectAccess(nativeOnly:nativeOnly)
            let chosen = grantedAccess?[name] ?? fallback
            let remote = access?[name] ?? chosen
            return (number,try KeyObjectAccess(nativeOnly:chosen.nativeOnly || remote.nativeOnly,depth:min(chosen.depth,remote.depth),pool:min(chosen.pool,remote.pool)))
        })
        var settings = configuration
        let names = Set(ids.map(String.init))
        settings.automation = settings.automation.filter { names.contains($0.key) }
        settings.streams = settings.streams?.filter { ids.contains($0) }
        settings.bleLifetimes = settings.bleLifetimes.filter { names.contains($0.key) }
        settings.calls = settings.calls.filter { names.contains($0.key) }
        let contents = try bundle(masterKey:owner.masterKey)
        var copy = try Self(owner:owner,label:label,numberIDs:ids,welcome:contents["welcome"] as? String ?? "",
            nativeOnly:nativeOnly,confirmation:false,access:rights,settings:settings)
        let bytes = try Self.makeBundle(owner:owner,numberIDs:ids,guestID:copy.guestID,
            welcome:contents["welcome"] as? String ?? "",confirmation:nil,existing:contents,renewBLE:true,
            automation:settings.automation,streamAllowed:settings.streams,bleLifetimes:settings.bleLifetimes)
        let secrets = try copy.secrets(masterKey:owner.masterKey)
        copy.bundleCipher = try GuestCrypto.encrypt(key:secrets.bundleKey,plaintext:bytes)
        copy.cloneSourceID = id
        return copy
    }
}
