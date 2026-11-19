import Foundation

/// A delivery hint, never an action request or a grant. The message ciphertext
/// still has to authenticate under the installed key before any acknowledgement.
public struct NativePushEvent: Codable, Equatable {
    public enum Kind: String, Codable { case message, sharedMessage = "share_message", additionalPart = "share_part" }
    public let kind: Kind
    public let server: String
    public let keyHash: String
    public let receivedAt: Date
    public init(payload: [String: Any], now: Date = Date()) throws {
        guard let content = payload["entrixy"] as? [String: Any],
              let raw = content["type"] as? String, let kind = Kind(rawValue:raw),
              let server = content["server"] as? String,
              let hash = content["hash"] as? String,
              hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0 else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        self.kind = kind; self.server = try GuestInvite.normalizeServer(server)
        keyHash = hash; receivedAt = now
    }
    public func validate() throws {
        let checked = try Self(payload:["entrixy":["type":kind.rawValue,"server":server,"hash":keyHash]],now:receivedAt)
        guard checked.server == server else { throw GuestCrypto.Failure.invalidEnvelope }
    }
    public var identity: String { server + ":" + keyHash + ":" + kind.rawValue }
}

public struct NativePushRegistration: Codable, Equatable {
    public enum Environment: String, Codable { case sandbox, production }
    public let token: String
    public let environment: Environment
    public init(token: String, environment: Environment) throws {
        // Apple tokens are opaque and their length must not be assumed to be32B.
        guard (32...512).contains(token.utf8.count), token.utf8.count.isMultiple(of:2),
              token.range(of:"^[a-f0-9]+$",options:.regularExpression) != nil else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        self.token = token; self.environment = environment
    }
    public func data() throws -> Data {
        _ = try Self(token:token,environment:environment)
        return try JSONEncoder().encode(self)
    }
}

public protocol NativePushTransport {
    func registerNativePush(_ registration: NativePushRegistration, invite: GuestInvite, fingerprint: String) async throws
    func removeNativePush(_ registration: NativePushRegistration, invite: GuestInvite, fingerprint: String) async throws
    func pendingNativeMessage(invite: GuestInvite, fingerprint: String) async throws -> String?
}

public extension NativePushTransport {
    func removeNativePush(_ registration: NativePushRegistration, invite: GuestInvite, fingerprint: String) async throws { throw GuestAPI.Failure(status:0,code:"unsupported") }
}

extension GuestAPI: NativePushTransport {
    public func registerNativePush(_ registration: NativePushRegistration, invite: GuestInvite, fingerprint: String) async throws {
        let data = try await post(invite:invite,fingerprint:fingerprint,endpoint:"native_push_register",body:registration.data())
        guard let reply = try JSONSerialization.jsonObject(with:data) as? [String:Any],reply["ok"] as? Bool == true else {
            throw Failure(status:0,code:"invalid_response")
        }
    }
    public func pendingNativeMessage(invite: GuestInvite, fingerprint: String) async throws -> String? {
        let data = try await post(invite:invite,fingerprint:fingerprint,endpoint:"message_pending",body:Data("{}".utf8))
        guard let reply = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw Failure(status:0,code:"invalid_response") }
        guard let raw = reply["cipher"] else { throw Failure(status:0,code:"invalid_response") }
        if raw is NSNull { return nil }
        guard let cipher = raw as? String, !cipher.isEmpty,cipher.utf8.count <= 4096 else { throw Failure(status:0,code:"invalid_response") }
        return cipher
    }
    public func removeNativePush(_ registration: NativePushRegistration, invite: GuestInvite, fingerprint: String) async throws {
        _ = try registration.data()
        let body = try JSONSerialization.data(withJSONObject:["token":registration.token,"environment":registration.environment.rawValue,"remove":true])
        _ = try await post(invite:invite,fingerprint:fingerprint,endpoint:"native_push_register",body:body)
    }
}
