import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol PromotionTransport {
    func fetch(_ body: Data) async throws -> Promotion?
    func view(id: Int, count: Int, installID: UUID) async throws
}

public final class PromotionAPI: PromotionTransport {
    private let sessions: ServerHTTPSession
    public convenience init() { self.init(configuration:.ephemeral) }
    init(configuration:URLSessionConfiguration) {
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        sessions = ServerHTTPSession(configuration:configuration)
    }
    private func post(_ endpoint:String,body:Data) async throws -> [String:Any] {
        let url = URL(string:"https://entrixy.com/api/" + endpoint + ".php")!
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody = body
        let (data,response) = try await sessions.session(for:url).data(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 262144,
              let json = try JSONSerialization.jsonObject(with:data) as? [String:Any], json["error"] == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        return json
    }
    public func fetch(_ body:Data) async throws -> Promotion? {
        guard body.count <= 4096, let request = try JSONSerialization.jsonObject(with:body) as? [String:Any],
              Set(request.keys) == Set(["lang","version","install_id","tags","age_days"]),
              let uuid = request["install_id"] as? String, UUID(uuidString:uuid) != nil else { throw GuestCrypto.Failure.invalidEnvelope }
        let json = try await post("promo",body:body)
        if json["promo"] is NSNull { return nil }
        guard let row = json["promo"] as? [String:Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        return try Promotion(json:row)
    }
    public func view(id:Int,count:Int,installID:UUID) async throws {
        guard id > 0, (1...10000).contains(count) else { throw GuestCrypto.Failure.invalidEnvelope }
        let data = try JSONSerialization.data(withJSONObject:["promo_id":id,"views":count,"install_id":installID.uuidString.lowercased()],options:.sortedKeys)
        let json = try await post("promo_view",body:data)
        guard (json["ok"] as? NSNumber)?.boolValue == true else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}
