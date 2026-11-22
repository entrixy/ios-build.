import Foundation

/// Only original local material. Current scopes/children must come from an
/// authenticated keyDelegateList for the same original source signing identity.
public struct AndroidPassedAccessMaterial {
    public let server: String
    public let group: String
    public let secret: Data
    public let label: String?
    public let created: Date
}

public extension AndroidBackupDocument {
    func passedAccessMaterial(sourceID: String, groups: Set<String>) throws -> [AndroidPassedAccessMaterial] {
        guard groups.count <= 5050 else { throw GuestCrypto.Failure.invalidEnvelope }
        let candidates = try guests().filter { try GuestSigningIdentity(server:$0.server,userKey:$0.userKey).id == sourceID }
        guard let source = candidates.first else { return [] }
        return try groups.sorted().compactMap { group in
            guard DelegationLink.code(group) else { throw GuestCrypto.Failure.invalidEnvelope }
            guard let encoded = try string("passed_wk_" + group), !encoded.isEmpty else { return nil }
            let secret = try GuestCrypto.decodeBase64URL(encoded)
            _ = try DelegationLink(server:source.server,group:group,secret:secret)
            let label = try string("passed_name_" + group)
            guard (label?.utf8.count ?? 0) <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
            return AndroidPassedAccessMaterial(server:source.server,group:group,secret:secret,
                label:label?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false ? label : nil,created:created)
        }
    }
}
