import Foundation

/// Owner-only grant assembly. Edits preserve the original token expiry unless
/// renewal is explicitly requested; polling must not endlessly extend access.
public enum BLEBundle {
    public static func row(object: OwnerObject, masterKey: Data, guestID: Int,
                           template: [String: Any], existing: [String: Any]? = nil,
                           renew: Bool = false, epoch: UInt64 = UInt64(Date().timeIntervalSince1970),
                           ttl: UInt32 = 86400) throws -> [String: Any] {
        guard object.kind == "ble", let id = object.numberID, let did = object.bleDeviceID,
              let wrapped = object.wrappedBLESecret, (1...65535).contains(guestID),
              (60...2_592_000).contains(ttl), epoch <= UInt64(UInt32.max) - UInt64(ttl) else { throw GuestCrypto.Failure.invalidEnvelope }
        let secret = try GuestCrypto.decrypt(key: masterKey, envelope: wrapped)
        let gid = UInt16(guestID)
        let guestKey = try BLECrypto.guestKey(ownerSecret: secret, guestID: gid)
        let stateKey = try BLECrypto.stateKey(ownerSecret: secret)
        var result = existing ?? [:]
        let expiry: UInt32
        if let existing, !renew {
            let grant = try BLEGuestGrant(row: existing)
            guard grant.objectID == id, grant.deviceID == did,
                  grant.guestKey == (try BLECrypto.guestKey(ownerSecret: secret, guestID: grant.guestID)),
                  grant.stateKey == stateKey,
                  grant.ownerSignature == (try BLECrypto.ownerSignature(ownerSecret: secret, token: grant.token)) else { throw GuestCrypto.Failure.invalidKey }
            // A child inherits the parent's expiry rather than extending it on
            // every owner sync. Its own DID/key/signature are freshly derived.
            expiry = grant.validUntil
        } else { expiry = UInt32(epoch + UInt64(ttl)) }
        let token = try BLECrypto.token(guestID: gid, validUntil: expiry)
        result["token"] = token.base64EncodedString()
        result["sig"] = try BLECrypto.ownerSignature(ownerSecret: secret, token: token).base64EncodedString()
        result["gkey"] = guestKey.base64EncodedString(); result["kstate"] = stateKey.base64EncodedString()
        result["valid_until"] = UInt64(expiry)
        let metadata = try object.metadata(masterKey: masterKey)
        result["id"] = id; result["did"] = UInt64(did)
        result["label"] = metadata["label"] as? String ?? "Bluetooth"
        result["avatar_type"] = metadata["avatar_type"] as? String ?? "preset:3"
        if result["rssi"] == nil { result["rssi"] = -90 }
        var policy = template
        if policy["ble_rad_o"] == nil { policy["ble_rad_o"] = 30 }
        result["tpl"] = policy
        _ = try BLEGuestGrant(row: result)
        return result
    }
}
