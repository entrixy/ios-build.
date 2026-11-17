import Foundation

/// Original owner key slots survive migration until a fresh snapshot supplies
/// the matching authenticated bundle/scope. No new user_key/K_guest is minted.
public struct AndroidOwnerKeyMaterial: Codable, Equatable, Identifiable {
    public let serverKeyID: Int
    public let userKey: String?
    public let wrappedBundleKey: String?
    public let guestID: Int?
    public let label: String
    public let signPublic: String?
    public var companyID: Int? = nil
    public var companyPublicKey: Data? = nil
    public var id: Int { serverKeyID }
    public func validate(masterKey: Data) throws {
        guard serverKeyID > 0, label.utf8.count <= 512, guestID == nil || (1...65535).contains(guestID!) else { throw GuestCrypto.Failure.invalidEnvelope }
        guard companyID == nil || companyID! > 0,
              companyPublicKey == nil || (companyID != nil && companyPublicKey?.count == 32) else { throw GuestCrypto.Failure.invalidEnvelope }
        if let userKey { _ = try GuestSigningIdentity(server: "material.invalid", userKey: userKey) }
        if let wrappedBundleKey { guard try GuestCrypto.decrypt(key: masterKey, envelope: wrappedBundleKey).count == 32 else { throw GuestCrypto.Failure.invalidKey } }
        if let signPublic {
            guard try GuestCrypto.decodeBase64URL(signPublic).count == 32 else { throw GuestCrypto.Failure.invalidKey }
            if let userKey {
                guard signPublic == GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: userKey).publicKey.rawRepresentation) else { throw GuestCrypto.Failure.invalidKey }
            }
        }
    }
}

public extension AndroidBackupDocument {
    func ownerKeyMaterial(server: String, masterKey: Data) throws -> [AndroidOwnerKeyMaterial] {
        let host = try GuestInvite.normalizeServer(server)
        var refs: [Int: String] = [:]
        let ownerHosts = try owners().map(\.server)
        for key in entries.keys {
            let prefix: String
            if key.hasPrefix("e2ee_guest_") { prefix = "e2ee_guest_" }
            else if key.hasPrefix("key_") { prefix = "key_" }
            else { continue }
            let reference = String(key.dropFirst(prefix.count))
            let id: Int
            let referenceHost: String
            if let at = reference.firstIndex(of: "@") {
                guard let parsed = Int(reference[..<at]), parsed > 0 else { continue }
                id = parsed; referenceHost = try GuestInvite.normalizeServer(String(reference[reference.index(after: at)...]))
            } else {
                guard let parsed = Int(reference), parsed > 0 else { continue }
                guard ownerHosts.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                id = parsed; referenceHost = try primaryServer()
            }
            if referenceHost == host {
                if let previous = refs[id], previous != reference { throw GuestCrypto.Failure.invalidEnvelope }
                refs[id] = reference
            }
        }
        var result: [AndroidOwnerKeyMaterial] = []
        for (id, ref) in refs.sorted(by: { $0.key < $1.key }) {
            let user = try string("key_\(ref)"), wrapped = try string("e2ee_guest_\(ref)")
            guard user != nil || wrapped != nil else { continue }
            let rawDID = try integer("ble_guest_did_\(ref)")
            if let rawDID { guard (1...65535).contains(rawDID) else { throw GuestCrypto.Failure.invalidEnvelope } }
            var material = AndroidOwnerKeyMaterial(serverKeyID: id, userKey: user, wrappedBundleKey: wrapped,
                guestID: rawDID.map(Int.init), label: try string("owner_guest_label_\(ref)") ?? "Восстановленный ключ",
                signPublic: try string("press_pub_\(ref)"))
            if let companyID = try integer("key_org_\(ref)"), companyID > 0, companyID <= Int.max {
                material.companyID = Int(companyID)
                if let encoded = try string("org_pub_\(ref)") ?? string("org_known_pub_\(companyID)@\(host)") {
                    guard let publicKey = Data(base64Encoded:encoded), publicKey.count == 32 else { throw GuestCrypto.Failure.invalidKey }
                    material.companyPublicKey = publicKey
                }
            }
            try material.validate(masterKey: masterKey); result.append(material)
        }
        guard result.count <= 1000 else { throw GuestCrypto.Failure.invalidEnvelope }
        return result
    }
}
