import Foundation
import EntrixyCore

protocol PhoneWebhookSending {
    func send(url: String, body: Data) async throws -> PhoneWebhookReply
}

/// One explicit POST. No app retries, cookies, cache or credential redirects.
final class PhoneWebhookTransport: NSObject, PhoneWebhookSending, URLSessionTaskDelegate {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration; super.init() }
    func send(url: String, body: Data) async throws -> PhoneWebhookReply {
        guard let components = URLComponents(string: url), ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, let target = components.url else { throw GuestCrypto.Failure.invalidEnvelope }
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
            data.append(byte)
        }
        guard let http = response as? HTTPURLResponse else { throw GuestCrypto.Failure.invalidEnvelope }
        return try PhoneWebhook.reply(status: http.statusCode, data: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
