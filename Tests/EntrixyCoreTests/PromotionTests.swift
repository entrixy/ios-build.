import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EntrixyCore

private final class PromotionStub: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}

final class PromotionTests: XCTestCase {
    override func tearDown() { PromotionStub.handler = nil; ServerSessionPolicy.shared.clear(); super.tearDown() }
    private func record(mode:String = "until_click") throws -> Promotion {
        try Promotion(json:["id":7,"title":"Entrixy","body":"Доступ для гостей","button_text":"Подробнее","button_url":"https://destination.invalid/",
            "display_mode":mode,"cache_ttl":900,"banner_url":"https://entrixy.com/uploads/banner.png"])
    }
    func testCacheTTLNullResultAndUntilClickSurviveRestartWithoutChangingInstallIdentity() throws {
        let now = Date(); var state = PromotionState(now:now)
        state.cached = try record(); state.cachedAt = now; state.cachedLanguage = "ru"
        XCTAssertFalse(state.needsRefresh(now:now.addingTimeInterval(899)))
        XCTAssertTrue(state.needsRefresh(now:now.addingTimeInterval(900)))
        XCTAssertTrue(state.needsRefresh(now:now.addingTimeInterval(-1)))
        state.clicked = [7]; XCTAssertNil(state.visible)
        let restarted = try JSONDecoder().decode(PromotionState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(restarted,state); XCTAssertEqual(restarted.installID,state.installID)
        state.cached = nil; XCTAssertFalse(state.needsRefresh(now:now.addingTimeInterval(500)))
        XCTAssertEqual(try record(mode:"date_range").destination?.absoluteString,"https://entrixy.com/api/go.php?pid=7")
    }
    func testRequestContainsOnlyCoarseTagsVersionLanguageAndUnrelatedInstallationUUID() throws {
        let now = Date(),state = PromotionState(now:now.addingTimeInterval(-2*86400))
        let data = try state.request(language:"ru",version:"1.0",tags:["has_call","has_guest"],now:now)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(json.keys),["lang","version","install_id","tags","age_days"])
        XCTAssertEqual(Set(json["tags"] as! [String]),["has_call","has_guest","new_install"])
        XCTAssertEqual(json["age_days"] as? Int,2)
        XCTAssertNotEqual(state.installID,PromotionState().installID)
        XCTAssertThrowsError(try state.request(language:"ru",version:"1",tags:["private-ssid"],now:now))
    }
    func testMalformedContentAndUnsafeRemoteAssetsCannotEnterCache() throws {
        for url in ["http://entrixy.com/image.png","https://user:secret@entrixy.com/image.png","file:///private/key"] {
            XCTAssertThrowsError(try Promotion(json:["id":7,"title":"Entrixy","banner_url":url]))
        }
        XCTAssertThrowsError(try Promotion(json:["id":true,"title":"Entrixy"]))
        XCTAssertThrowsError(try Promotion(json:["id":7,"title":"Entrixy","height_dp":100000]))
        var state = PromotionState(); state.clicked = [7,7]
        XCTAssertThrowsError(try state.validate())
    }
    func testCatalogueAndViewsUseOnlyTrustedOriginAndRespectServerPrivacyGate() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PromotionStub.self]
        let api = PromotionAPI(configuration:config)
        var calls = 0
        PromotionStub.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.host,"entrixy.com"); XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertNil(request.value(forHTTPHeaderField:"Authorization")); XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
            if request.url?.lastPathComponent == "promo.php" { return Data(#"{"promo":null}"#.utf8) }
            XCTAssertEqual(request.url?.lastPathComponent,"promo_view.php")
            return Data(#"{"ok":1}"#.utf8)
        }
        let state = PromotionState()
        let body = try state.request(language:"ru",version:"1",tags:[],now:Date())
        let result = try await api.fetch(body); XCTAssertNil(result)
        try await api.view(id:7,count:1,installID:state.installID)
        XCTAssertEqual(calls,2)
        ServerSessionPolicy.shared.install({ _ in },authorize:{ _ in throw URLError(.notConnectedToInternet) },networkPrivacyEnforced:true)
        do { _ = try await api.fetch(body); XCTFail("Blocked catalogue went on wire") } catch { }
        XCTAssertEqual(calls,2)
    }
}
