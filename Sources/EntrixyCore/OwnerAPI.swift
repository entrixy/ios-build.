import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol OwnerTransport {
    func live(server: String, credentials: OwnerCredentials, fingerprint: String) throws -> OwnerLiveTransport
    func register(server: String, accessCode: String) async throws -> OwnerCredentials
    func sync(server: String, credentials: OwnerCredentials, fingerprint: String) async throws -> Data
    func mutate(server: String, credentials: OwnerCredentials, fingerprint: String, operation: OwnerOperation, body: Data) async throws -> Data
}

public extension OwnerTransport {
    func live(server: String, credentials: OwnerCredentials, fingerprint: String) throws -> OwnerLiveTransport { throw GuestCrypto.Failure.invalidEnvelope }
    func mutate(server: String, credentials: OwnerCredentials, fingerprint: String, operation: OwnerOperation, body: Data) async throws -> Data {
        throw GuestCrypto.Failure.invalidEnvelope
    }
}

/// Mirrors Android Api.registerHost/hostSync, without credential redirects or retries.
public final class OwnerAPI: OwnerTransport {
    public struct Failure: Error {
        public let status: Int
        public let code: String
    }
    private let session: URLSession
    public convenience init() { self.init(configuration: .ephemeral) }
    init(configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func live(server: String, credentials: OwnerCredentials, fingerprint: String) throws -> OwnerLiveTransport {
        try credentials.validate()
        guard fingerprint.count == 64, fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let url = URL(string: "wss://\(try GuestInvite.normalizeServer(server))/ws") else { throw GuestCrypto.Failure.invalidEnvelope }
        return OwnerLiveSession(socket: session.webSocketTask(with: url), credentials: credentials, fingerprint: fingerprint)
    }

    public func register(server: String, accessCode: String = "") async throws -> OwnerCredentials {
        let fields = accessCode.isEmpty ? [:] : ["access_code": accessCode]
        let data = try await post(server: server, endpoint: "register_host", body: fields)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = body["device_id"] as? String, let secret = body["device_secret"] as? String else {
            throw Failure(status: 200, code: "invalid_registration")
        }
        return try OwnerCredentials(deviceID: id, deviceSecret: secret)
    }

    public func sync(server: String, credentials: OwnerCredentials, fingerprint: String) async throws -> Data {
        try credentials.validate()
        guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure(status: 0, code: "invalid_fingerprint")
        }
        let data = try await post(server: server, endpoint: "host_sync", body: [
            "device_id": credentials.deviceID, "device_secret": credentials.deviceSecret, "device_fp": fingerprint
        ])
        _ = try OwnerSnapshot.decode(data)
        return data
    }

    public func mutate(server: String, credentials: OwnerCredentials, fingerprint: String, operation: OwnerOperation, body: Data) async throws -> Data {
        try credentials.validate()
        guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              var fields = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              fields["device_id"] == nil, fields["device_secret"] == nil, fields["device_fp"] == nil else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        fields["device_id"] = credentials.deviceID
        fields["device_secret"] = credentials.deviceSecret
        fields["device_fp"] = fingerprint
        return try await post(server: server, endpoint: operation.rawValue, body: fields)
    }

    private func post(server: String, endpoint: String, body: [String: Any]) async throws -> Data {
        let host = try GuestInvite.normalizeServer(server)
        guard let url = URL(string: "https://\(host)/api/\(endpoint).php") else { throw Failure(status: 0, code: "invalid_server") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, code: "invalid_response") }
        guard data.count <= 4_194_304 else { throw Failure(status: http.statusCode, code: "response_too_large") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(status: http.statusCode, code: "invalid_response")
        }
        if let code = json["error"] as? String { throw Failure(status: http.statusCode, code: code) }
        guard (200..<300).contains(http.statusCode) else { throw Failure(status: http.statusCode, code: "invalid_response") }
        return data
    }
}
