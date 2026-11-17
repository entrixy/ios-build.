import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EntrixyCore

private final class SessionPolicyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var hold = false
    private var started: (@Sendable () -> Void)?
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func reset(hold: Bool = false,started: (@Sendable () -> Void)? = nil) {
        lock.lock(); requests = 0; self.hold = hold; self.started = started; lock.unlock()
    }
    func begin() -> Bool {
        lock.lock(); requests += 1; let hold = self.hold, callback = started; lock.unlock()
        callback?(); return hold
    }
}
private final class SessionPolicyProtocol: URLProtocol {
    static let probe = SessionPolicyProbe()
    private var fallback: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "policy.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.probe.begin() {
            let work = DispatchWorkItem { [weak self] in self?.reply() }; fallback = work
            DispatchQueue.global().asyncAfter(deadline:.now()+5,execute:work)
        } else { reply() }
    }
    private func reply() {
        let bytes = try! JSONSerialization.data(withJSONObject:["device_id":String(repeating:"a",count:32),"device_secret":String(repeating:"b",count:64)])
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { fallback?.cancel(); fallback = nil }
}

final class ServerSessionPolicyTests: XCTestCase {
    private enum Blocked: Error { case network }
    private func owner() -> OwnerAPI {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SessionPolicyProtocol.self]
        return OwnerAPI(configuration:configuration)
    }
    override func setUp() { ServerSessionPolicy.shared.clear(); SessionPolicyProtocol.probe.reset() }
    override func tearDown() { ServerSessionPolicy.shared.clear(); SessionPolicyProtocol.probe.reset(); super.tearDown() }
    func testNewRuleBlocksBeforeHTTPAndTheSameClientRecoversOnlyAfterItsRemoval() async throws {
        let api = owner()
        ServerSessionPolicy.shared.install({ _ in },authorize:{ _ in throw Blocked.network })
        do { _ = try await api.register(server:"policy.invalid",accessCode:""); XCTFail("Request bypassed rule") }
        catch { XCTAssertTrue(error is Blocked) }
        XCTAssertEqual(SessionPolicyProtocol.probe.count,0)
        ServerSessionPolicy.shared.clear()
        let credentials = try await api.register(server:"policy.invalid",accessCode:"")
        XCTAssertEqual(credentials.deviceID,String(repeating:"a",count:32))
        XCTAssertEqual(SessionPolicyProtocol.probe.count,1)
    }
    func testOwnerAndGuestWebSocketsAreCheckedBeforeTheyCanStart() async throws {
        let owner = owner(), guest = GuestAPI()
        let credentials = try OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        let invite = try GuestInvite.parse("https://policy.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"+String(repeating:"A",count:43))
        ServerSessionPolicy.shared.install({ _ in },authorize:{ _ in throw Blocked.network })
        XCTAssertThrowsError(try owner.live(server:"policy.invalid",credentials:credentials,fingerprint:String(repeating:"c",count:64))) { XCTAssertTrue($0 is Blocked) }
        XCTAssertThrowsError(try guest.live(invite:invite,fingerprint:"fixture")) { XCTAssertTrue($0 is Blocked) }
        do { _ = try await guest.snapshot(invite:invite,fingerprint:"fixture"); XCTFail("Snapshot bypassed rule") }
        catch { XCTAssertTrue(error is Blocked) }
        XCTAssertEqual(SessionPolicyProtocol.probe.count,0)
    }
    func testRuleChangeCancelsAnInFlightRequestWithoutResubmittingIt() async throws {
        let started = expectation(description:"One request began")
        SessionPolicyProtocol.probe.reset(hold:true,started:{ started.fulfill() })
        let api = owner()
        let pending = Task { try await api.register(server:"policy.invalid",accessCode:"") }
        await fulfillment(of:[started],timeout:3)
        ServerSessionPolicy.shared.install({ _ in },authorize:{ _ in throw Blocked.network })
        do { _ = try await pending.value; XCTFail("Cancelled request completed") } catch { }
        XCTAssertEqual(SessionPolicyProtocol.probe.count,1)
        do { _ = try await api.register(server:"policy.invalid",accessCode:""); XCTFail("New request bypassed rule") }
        catch { XCTAssertTrue(error is Blocked) }
        XCTAssertEqual(SessionPolicyProtocol.probe.count,1)
    }
}
