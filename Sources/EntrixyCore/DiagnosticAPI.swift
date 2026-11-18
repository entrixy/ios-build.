import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol DiagnosticTransport {
    func send(_ report: DiagnosticReport) async throws
}

/// Android's trusted update/report origin. Custom access servers cannot select
/// the diagnostic destination or receive a password, cookie or account token.
public final class DiagnosticAPI: DiagnosticTransport {
    private let sessions: ServerHTTPSession
    public convenience init() { self.init(configuration:.ephemeral) }
    init(configuration: URLSessionConfiguration) {
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        sessions = ServerHTTPSession(configuration:configuration)
    }
    public func send(_ report: DiagnosticReport) async throws {
        let url = URL(string:"https://entrixy.com/api/crash_report.php")!
        var request = URLRequest(url:url)
        request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpShouldHandleCookies = false; request.httpBody = try report.body()
        let (data,response) = try await sessions.session(for:url).data(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 16384,
              let json = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              (json["ok"] as? NSNumber)?.intValue == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}
