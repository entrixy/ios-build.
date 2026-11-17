import XCTest
import Network
import EntrixyCore
@testable import Entrixy

@MainActor final class ServerPrivacyRouterTests: XCTestCase {
    func testPersistedRestrictionReachesTheRealServerClientAndNeverFallsBack() async throws {
        guard #available(iOS 17.0,*) else { throw XCTSkip("Constrained public routing requires iOS17") }
        var routes: [ServerNetworkRoute] = []
        let router = ServerPrivacyRouter(connect:{ _,_,route in
            routes.append(route)
            return NWConnection(host:"127.0.0.1",port:1,using:.tcp)
        })
        defer { router.stop(); ServerSessionPolicy.shared.install({ _ in }) }
        router.update(restricted:true,cellularAuthorized:true)
        let client = OwnerAPI() // Existing clients must also adopt the route.
        let started = await router.start(); XCTAssertTrue(started)
        do { _ = try await client.register(server:"server.invalid",accessCode:""); XCTFail("No upstream service exists") } catch { }
        XCTAssertEqual(routes,[.cellular])
        XCTAssertEqual(router.route,.cellular)
    }
    func testStoppingRoutingBlocksAnExistingClientBeforeAnyNewConnection() async throws {
        var attempts = 0
        let router = ServerPrivacyRouter(connect:{ _,_,_ in
            attempts += 1; return NWConnection(host:"127.0.0.1",port:1,using:.tcp)
        })
        defer { router.stop(); ServerSessionPolicy.shared.install({ _ in }) }
        let client = OwnerAPI()
        let started = await router.start(); XCTAssertTrue(started)
        router.stop()
        do { _ = try await client.register(server:"server.invalid",accessCode:""); XCTFail("Stopped router permitted a request") }
        catch { XCTAssertEqual((error as? GuestAPI.Failure)?.code,"network_policy_blocked") }
        XCTAssertEqual(attempts,0)
        XCTAssertFalse(router.ready)
    }
}
