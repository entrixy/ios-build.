import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// No redirects, cookies, background retries, or real-world actuation in this transport.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public protocol GuestMigrationTransport {
    func move(invite: GuestInvite, oldFingerprint: String, newFingerprint: String) async throws
    func move(identity: GuestSigningIdentity, oldFingerprint: String, newFingerprint: String) async throws
    func recover(identity: GuestSigningIdentity, bundleKey: Data?, recipient: BundleKeySeal.Recipient?, fingerprint: String) async throws -> GuestInvite?
}
public extension GuestMigrationTransport {
    func move(identity: GuestSigningIdentity, oldFingerprint: String, newFingerprint: String) async throws { throw GuestAPI.Failure(status: 0, code: "migration_unsupported") }
    func recover(identity: GuestSigningIdentity, bundleKey: Data?, recipient: BundleKeySeal.Recipient?, fingerprint: String) async throws -> GuestInvite? { throw GuestAPI.Failure(status: 0, code: "migration_unsupported") }
}

public final class GuestAPI: GuestMigrationTransport, DelegationTransport, GuestMessageTransport {
    public struct Failure: Error, Equatable {
        public let status: Int
        public let code: String
        public init(status: Int, code: String) { self.status = status; self.code = code }
    }
    private let session: URLSession

    public convenience init() { self.init(configuration: .ephemeral) }

    init(configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func post(invite: GuestInvite, fingerprint: String, endpoint: String,
                      body: Data, useInvitationKey: Bool = false) async throws -> Data {
        try await signedPost(invite: invite, fingerprint: fingerprint, endpoint: endpoint, body: body, useInvitationKey: useInvitationKey)
    }

    private func signedPost(invite: GuestInvite, fingerprint: String, endpoint: String, body: Data,
                            useInvitationKey: Bool = false, action: DelegationOperation? = nil) async throws -> Data {
        try await signedPost(identity: GuestSigningIdentity(invite), fingerprint: fingerprint, endpoint: endpoint,
            body: body, useInvitationKey: useInvitationKey, action: action)
    }
    private func signedPost(identity: GuestSigningIdentity, fingerprint: String, endpoint: String, body: Data,
                            useInvitationKey: Bool = false, action: DelegationOperation? = nil) async throws -> Data {
        guard endpoint.range(of: "^[a-z_]+$", options: .regularExpression) != nil,
              let url = URL(string: "https://\(try GuestInvite.normalizeServer(identity.server))/api/\(endpoint).php") else {
            throw Failure(status: 0, code: "invalid_endpoint")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let action { components.queryItems = [URLQueryItem(name: "a", value: action.rawValue)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let headers = try GuestCrypto.headers(userKey: identity.userKey, endpoint: endpoint, body: body,
                                               deviceFingerprint: useInvitationKey ? nil : fingerprint)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }

    public func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              fingerprint.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure(status: 0, code: "bad_input") }
        json["device_fp"] = fingerprint
        let bytes = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        return try await signedPost(invite: invite, fingerprint: fingerprint, endpoint: "key_delegate", body: bytes, action: operation)
    }

    public func delegationInfo(server: String, group: String) async throws -> Data {
        guard DelegationLink.code(group) else { throw Failure(status: 0, code: "bad_input") }
        return try await publicDelegate(server: server, action: "info", body: JSONSerialization.data(withJSONObject: ["code": group], options: .sortedKeys))
    }

    public func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data {
        try await publicDelegate(server: pending.link.server, action: "redeem", body: pending.request(fingerprint: fingerprint))
    }

    public func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite? {
        try pending.validate()
        guard pending.parts.contains(where: { $0.code == part.code && $0.userKey == part.userKey }) else { throw Failure(status: 0, code: "bad_input") }
        let identity = try GuestSigningIdentity(server: pending.link.server, userKey: part.userKey)
        try await bind(identity: identity, fingerprint: fingerprint)
        let bytes = try await signedPost(identity: identity, fingerprint: fingerprint, endpoint: "key_bundle", body: Data("{}".utf8))
        guard let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure(status: 0, code: "invalid_response") }
        guard let sealedKey = row["key_cipher"] as? String, !sealedKey.isEmpty,
              let cipher = row["bundle_cipher"] as? String, !cipher.isEmpty else { return nil }
        let invitation = try pending.invitation(part: part, keyCipher: sealedKey)
        let plaintext = try GuestCrypto.decrypt(key: invitation.bundleKey, envelope: cipher)
        guard try JSONSerialization.jsonObject(with: plaintext) is [String: Any] else { throw Failure(status: 0, code: "invalid_bundle") }
        return invitation
    }

    private func publicDelegate(server: String, action: String, body: Data) async throws -> Data {
        guard let url = URL(string: "https://\(try GuestInvite.normalizeServer(server))/api/key_delegate.php?a=\(action)") else { throw Failure(status: 0, code: "invalid_endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, code: "invalid_response") }
        guard data.count <= 1_048_576 else { throw Failure(status: http.statusCode, code: "response_too_large") }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let code = object?["error"] as? String { throw Failure(status: http.statusCode, code: code) }
        guard (200..<300).contains(http.statusCode), object != nil else {
            throw Failure(status: http.statusCode, code: "invalid_response")
        }
        return data
    }

    public func acknowledgeMessage(invite: GuestInvite, fingerprint: String, kind: MessageAcknowledgement, hash: String) async throws {
        guard hash.utf8.count == 24, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure(status: 0, code: "bad_input") }
        let body = try JSONSerialization.data(withJSONObject: ["kind": kind.rawValue, "h": hash], options: .sortedKeys)
        let response = try await post(invite: invite, fingerprint: fingerprint, endpoint: "message_ack", body: body)
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any], (json["ok"] as? NSNumber)?.boolValue == true else { throw Failure(status: 0, code: "invalid_response") }
    }

    /// If the first response was lost, try the same device pair before invitation signing.
    public func bind(invite: GuestInvite, fingerprint: String) async throws {
        try await bind(identity: GuestSigningIdentity(invite), fingerprint: fingerprint)
    }
    public func bind(identity: GuestSigningIdentity, fingerprint: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "device_fp": fingerprint,
            "device_pub": GuestCrypto.devicePublicKey(userKey: identity.userKey, fingerprint: fingerprint)
        ], options: [.sortedKeys])
        let response: Data
        do { response = try await signedPost(identity: identity, fingerprint: fingerprint, endpoint: "key_bind", body: body) }
        catch let failure as Failure where failure.status == 403 && failure.code == "bad_key" {
            response = try await signedPost(identity: identity, fingerprint: fingerprint, endpoint: "key_bind", body: body, useInvitationKey: true)
        }
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              (result["ok"] as? NSNumber)?.boolValue == true,
              (result["device_key"] as? NSNumber)?.boolValue == true else {
            throw Failure(status: 0, code: "device_binding_failed")
        }
    }

    /// A migration is authorized by the old device key; repeating after a lost reply
    /// first checks the already-installed NEW pair, rather than generating another identity.
    public func move(invite: GuestInvite, oldFingerprint: String, newFingerprint: String) async throws {
        try await move(identity: GuestSigningIdentity(invite), oldFingerprint: oldFingerprint, newFingerprint: newFingerprint)
    }
    public func move(identity: GuestSigningIdentity, oldFingerprint: String, newFingerprint: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["device_fp": newFingerprint,
            "device_pub": GuestCrypto.devicePublicKey(userKey: identity.userKey, fingerprint: newFingerprint), "move": 1], options: .sortedKeys)
        let response: Data
        do { response = try await signedPost(identity: identity, fingerprint: newFingerprint, endpoint: "key_bind", body: body) }
        catch let failure as Failure where failure.status == 403 && failure.code == "bad_key" {
            do { response = try await signedPost(identity: identity, fingerprint: oldFingerprint, endpoint: "key_bind", body: body) }
            catch let failure as Failure where failure.status == 403 && failure.code == "bad_key" {
                // Base-key signing can bind a never-used key; the server forbids it from moving a bound one.
                response = try await signedPost(identity: identity, fingerprint: oldFingerprint, endpoint: "key_bind", body: body, useInvitationKey: true)
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              (json["ok"] as? NSNumber)?.boolValue == true,
              (json["device_key"] as? NSNumber)?.boolValue == true else { throw Failure(status: 0, code: "device_binding_failed") }
    }

    public func recover(identity: GuestSigningIdentity, bundleKey: Data?, recipient: BundleKeySeal.Recipient?, fingerprint: String) async throws -> GuestInvite? {
        if let bundleKey { guard bundleKey.count == 32 else { throw Failure(status: 0, code: "invalid_bundle") } }
        if let recipient { try BundleKeySeal.validate(recipient) }
        let bytes = try await signedPost(identity: identity, fingerprint: fingerprint, endpoint: "key_bundle", body: Data("{}".utf8))
        guard let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure(status: 0, code: "invalid_response") }
        guard let cipher = row["bundle_cipher"] as? String, !cipher.isEmpty else { return nil }
        let key: Data
        if let recipient, let sealed = row["key_cipher"] as? String, !sealed.isEmpty { key = try BundleKeySeal.open(sealed, recipient: recipient) }
        else if let bundleKey { key = bundleKey }
        else { return nil }
        let clear = try GuestCrypto.decrypt(key: key, envelope: cipher)
        guard try JSONSerialization.jsonObject(with: clear) is [String: Any] else { throw Failure(status: 0, code: "invalid_bundle") }
        return try identity.invitation(bundleKey: key)
    }

    public func bundle(invite: GuestInvite, fingerprint: String) async throws -> Data {
        try await bundleWithDepth(invite: invite, fingerprint: fingerprint).contents
    }
    public func bundleWithDepth(invite: GuestInvite, fingerprint: String) async throws -> (contents: Data, depth: Int) {
        let response = try await post(invite: invite, fingerprint: fingerprint, endpoint: "key_bundle", body: Data("{}".utf8))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let cipher = object["bundle_cipher"] as? String, !cipher.isEmpty else {
            throw Failure(status: 0, code: "awaiting_owner")
        }
        let raw = object["delegate_depth"]
        let depth = raw == nil ? 0 : (raw as? Int ?? -1)
        guard (0...5).contains(depth) else { throw Failure(status: 0, code: "invalid_delegate_depth") }
        if let raw {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(depth) else { throw Failure(status: 0, code: "invalid_delegate_depth") }
        }
        return (try GuestCrypto.decrypt(key: invite.bundleKey, envelope: cipher), depth)
    }
    /// Read-only initial WSS snapshot; never sends an opening or retries a command.
    public func snapshot(invite: GuestInvite, fingerprint: String) async throws -> Data {
        guard let url = URL(string: "wss://\(try GuestInvite.normalizeServer(invite.server))/ws") else {
            throw Failure(status: 0, code: "invalid_server")
        }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1_048_576
        socket.resume()
        let deadline = Task {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
        let hello = try GuestCrypto.hello(userKey: invite.userKey, fingerprint: fingerprint)
        let message = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])
        try await socket.send(.string(String(decoding: message, as: UTF8.self)))
        for _ in 0..<32 {
            let frame = try await socket.receive()
            let data: Data
            switch frame {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: throw Failure(status: 0, code: "invalid_response")
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure(status: 0, code: "invalid_response")
            }
            if object["type"] as? String == "error" {
                throw Failure(status: 0, code: object["reason"] as? String ?? "server_error")
            }
            if object["type"] as? String == "guest_ok" {
                _ = try GuestEvent.decode(data)
                return data
            }
        }
        throw Failure(status: 0, code: "missing_guest_snapshot")
    }

    public func live(invite: GuestInvite, fingerprint: String) throws -> GuestLiveSession {
        let server = try GuestInvite.normalizeServer(invite.server)
        guard let url = URL(string: "wss://\(server)/ws") else { throw Failure(status: 0, code: "invalid_server") }
        return GuestLiveSession(socket: session.webSocketTask(with: url), invite: invite, fingerprint: fingerprint)
    }
}
