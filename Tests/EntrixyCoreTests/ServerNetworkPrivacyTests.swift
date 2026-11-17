import XCTest
@testable import EntrixyCore

final class ServerNetworkPrivacyTests: XCTestCase {
    private func network(_ ssid: String = "Home",_ bssid: String? = "aa:bb:cc:dd:ee:ff") throws -> PrivacyNetwork { try PrivacyNetwork(ssid:ssid,bssid:bssid) }
    private func decision(own: [PrivacyNetwork] = [],received: [PrivacyNetwork] = [],wifi: Bool? = true,ssid: String? = nil,bssid: String? = nil,cell: Bool = false,available: Bool = true) -> ServerNetworkDecision {
        .evaluate(own:own,received:received,isWiFi:wifi,ssid:ssid,bssid:bssid,cellularAuthorized:cell,constrainedRoutingAvailable:available)
    }
    func testWireRoundTripUsesAndroidNamesAndOptionalAddress() throws {
        let value = try network("Home","AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(value.bssid,"aa:bb:cc:dd:ee:ff")
        let json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:String]
        XCTAssertEqual(json,["s":"Home","b":"aa:bb:cc:dd:ee:ff"])
        XCTAssertEqual(try PrivacyNetwork.decode([value.wire]),[value])
        XCTAssertEqual(try JSONDecoder().decode(PrivacyNetwork.self,from:JSONEncoder().encode(value)),value)
        XCTAssertNil(try PrivacyNetwork(ssid:"Guest").wire["b"])
    }
    func testOwnAndReceivedRulesMatchSSIDOrAddressWithoutChangingCaseSemantics() throws {
        let rule = try network()
        XCTAssertEqual(decision(own:[rule],ssid:"home").route,.blocked)
        XCTAssertTrue(decision(own:[rule],ssid:"home").ownRule)
        XCTAssertEqual(decision(received:[rule],ssid:"Other",bssid:"AA:BB:CC:DD:EE:FF",cell:true).route,.cellular)
        XCTAssertFalse(decision(received:[rule],ssid:"Home").ownRule)
        XCTAssertEqual(decision(own:[rule],ssid:"Other",bssid:"01:02:03:04:05:06").route,.system)
    }
    func testNoRulesPreserveTheSystemRouteEvenWhenItsNetworkIsUnknown() {
        XCTAssertEqual(decision(wifi:nil,available:false).route,.system)
        XCTAssertFalse(decision(wifi:nil).unknownWiFi)
    }
    func testUnknownWiFiFailsClosedUnlessCellularWasExplicitlyAuthorized() throws {
        let rule = try network()
        XCTAssertEqual(decision(own:[rule]).route,.blocked)
        XCTAssertTrue(decision(own:[rule]).unknownWiFi)
        XCTAssertEqual(decision(own:[rule],cell:true).route,.cellular)
        XCTAssertEqual(decision(own:[rule],wifi:nil,cell:true).route,.cellular)
        XCTAssertEqual(decision(own:[rule],wifi:false).route,.system)
    }
    func testUnsupportedRoutingCannotLeakDuringALaterInterfaceChange() throws {
        XCTAssertEqual(decision(own:[try network()],wifi:false,cell:true,available:false).route,.blocked)
    }
    func testMalformedRulesAreRejectedRatherThanSilentlyDiscarded() throws {
        for raw: Any in [["Home"],[["b":"aa:bb:cc:dd:ee:ff"]],[["s":"Home","b":42]],[["s":"\n"]],Array(repeating:["s":"Home"],count:257)] {
            XCTAssertThrowsError(try PrivacyNetwork.decode(raw))
        }
        XCTAssertThrowsError(try network("Home","02:00:00:00:00:00"))
        XCTAssertThrowsError(try network("Home","not-an-address"))
        XCTAssertThrowsError(try network(String(repeating:"a",count:257)))
    }
    func testBackupMergeRetainsLocalCellularConsentAndDeduplicatesNetworkNames() throws {
        let local = try NetworkPrivacyPreferences(own:[network("Home",nil)])
        let imported = try NetworkPrivacyPreferences(own:[network("HOME",nil),network("Office",nil)],cellularAuthorized:true)
        let merged = try local.merging(imported)
        XCTAssertEqual(merged.own.map(\.ssid),["Home","Office"])
        XCTAssertFalse(merged.cellularAuthorized)
        let authorized = try NetworkPrivacyPreferences(cellularAuthorized:true)
        XCTAssertTrue(try authorized.merging(local).cellularAuthorized)
        XCTAssertEqual(try JSONDecoder().decode(NetworkPrivacyPreferences.self,from:JSONEncoder().encode(merged)),merged)
        XCTAssertThrowsError(try NetworkPrivacyPreferences(own:[network("Home",nil),network("HOME",nil)]))
    }
    func testAndroidRulesStayScopedAndNeverChangeTheRetainedArchive() throws {
        let entries: [String:Any] = [
            "blocked_wifi":["t":"s","v":"[{\"s\":\"Home\"}]"],
            "blocked_wifi_g_7":["t":"s","v":"[{\"s\":\"Owner home\"}]"],
            "blocked_wifi_g_8":["t":"s","v":"[{\"s\":\"Other home\"}]"],
            "unmapped_setting":["t":"s","v":"preserve me"]]
        let bytes = try JSONSerialization.data(withJSONObject:["app":"entrixy","ver":1,"created":1700000000,"device":"test","count":entries.count,"entries":entries])
        let document = try AndroidBackupDocument(bytes)
        XCTAssertEqual(try document.networkPrivacyPreferences().own.map(\.ssid),["Home"])
        XCTAssertFalse(try document.networkPrivacyPreferences().cellularAuthorized)
        XCTAssertEqual(try document.guestPrivacyNetworks(localID:7).map(\.ssid),["Owner home"])
        XCTAssertEqual(try document.guestPrivacyNetworks(localID:8).map(\.ssid),["Other home"])
        XCTAssertEqual(try document.guestPrivacyNetworks(localID:9),[])
        XCTAssertThrowsError(try document.guestPrivacyNetworks(localID:0))
        XCTAssertEqual(document.original,bytes)
    }
}

final class ServerProxyConnectTests: XCTestCase {
    private let authorization = "Basic " + Data("Entrixy:public-test-capability".utf8).base64EncodedString()
    private func header(_ target: String = "server.invalid:443",extra: String = "") -> Data {
        Data("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\nProxy-Authorization: \(authorization)\r\n\(extra)\r\n".utf8)
    }
    func testConnectPreservesOpaqueTLSBytesAndNormalizesOnlyItsAuthority() throws {
        let tls = Data([0x16,0x03,0x03,0xff,0,1])
        let value = try ServerProxyConnect(header("Server.Invalid:8443")+tls,authorization:authorization)
        XCTAssertEqual(value.server,"server.invalid:8443"); XCTAssertEqual(value.host,"Server.Invalid")
        XCTAssertEqual(value.port,8443); XCTAssertEqual(value.remainder,tls)
    }
    func testIPv6TargetKeepsItsPortAndProducesAnUnbracketedNetworkHost() throws {
        let value = try ServerProxyConnect(header("[::1]:9443"),authorization:authorization)
        XCTAssertEqual(value.server,"[::1]:9443"); XCTAssertEqual(value.host,"::1"); XCTAssertEqual(value.port,9443)
    }
    func testAnIncompleteHeaderWaitsButOversizedInputDoesNot() {
        XCTAssertThrowsError(try ServerProxyConnect(Data("CONNECT server.invalid:443 HTTP/1.1\r\n".utf8),authorization:authorization)) {
            guard case ServerProxyConnect.Failure.incomplete = $0 else { return XCTFail("Not an incomplete header") }
        }
        XCTAssertThrowsError(try ServerProxyConnect(Data(repeating:65,count:16385),authorization:authorization))
        XCTAssertThrowsError(try ServerProxyConnect(header(extra:"X: "+String(repeating:"x",count:16384)+"\r\n"),authorization:authorization))
    }
    func testWrongOrAbsentProxyCapabilityCannotOpenAnUpstream() {
        for expected in ["",authorization+"x"] { XCTAssertThrowsError(try ServerProxyConnect(header(),authorization:expected)) }
        let missing = Data("CONNECT server.invalid:443 HTTP/1.1\r\nHost: server.invalid:443\r\n\r\n".utf8)
        XCTAssertThrowsError(try ServerProxyConnect(missing,authorization:authorization))
    }
    func testHeaderSmugglingAndNonConnectRequestsAreRejected() {
        for extra in ["proxy-authorization: \(authorization)\r\n","Transfer-Encoding: chunked\r\n","Content-Length: 1\r\n"," folded: value\r\n","Host: other.invalid:443\r\n"] {
            XCTAssertThrowsError(try ServerProxyConnect(header(extra:extra),authorization:authorization),extra)
        }
        let get = Data("GET https://server.invalid/ HTTP/1.1\r\nProxy-Authorization: \(authorization)\r\n\r\n".utf8)
        XCTAssertThrowsError(try ServerProxyConnect(get,authorization:authorization))
        for target in ["user:pass@server.invalid:443","server.invalid:443/path","server.invalid:443?x=y","server.invalid:443#fragment","server.invalid","server.invalid:0"] {
            XCTAssertThrowsError(try ServerProxyConnect(header(target),authorization:authorization),target)
        }
    }
}
