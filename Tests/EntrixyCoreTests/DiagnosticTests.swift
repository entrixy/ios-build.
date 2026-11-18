import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EntrixyCore

private final class DiagnosticStub: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

final class DiagnosticTests: XCTestCase {
    private let facts = DiagnosticFacts(owners:1,guests:2,objects:3,pending:0,connected:1,storageReady:true,privacyBlocked:false)
    private func report() throws -> DiagnosticReport { try DiagnosticReport(kind:.manual,appVersion:"1.0",build:"7",osVersion:"26.4",facts:facts) }
    override func tearDown() { DiagnosticStub.handler = nil; ServerSessionPolicy.shared.clear(); super.tearDown() }
    func testMetricKitWrapperIsRebuiltWithoutPathsMessagesOrUnknownPrivateFields() throws {
        let raw = Data(#"{"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"Entrixy","binaryUUID":"C45720C7-4901-4979-8087-536682A0D772","address":4295434016,"offsetIntoBinaryTextSegment":123,"symbol":"private-secret","path":"/private/user-name","key":"private-key","subFrames":[]}]}],"callStackPerThread":true},"exceptionReason":"private URL https://private.invalid/token"}"#.utf8)
        let crash = try DiagnosticCrash(recordedAt:Date(),stack:raw)
        let safe = String(decoding:crash.stack,as:UTF8.self)
        XCTAssertFalse(safe.contains("private")); XCTAssertFalse(safe.contains("symbol")); XCTAssertTrue(safe.contains("4295434016"))
        try crash.validate()
        XCTAssertEqual(try DiagnosticCrash(recordedAt:crash.recordedAt,stack:crash.stack),crash)
    }
    func testMalformedNumericStacksAndOversizedReportsAreRejected() throws {
        for stack in [#"{"callStacks":[{"callStackRootFrames":[{"address":true}]}]}"#,
                      #"{"callStacks":[{"callStackRootFrames":[{"sampleCount":-1}]}]}"#,
                      #"{"callStacks":"invalid"}"#] {
            XCTAssertThrowsError(try DiagnosticCrash(recordedAt:Date(),stack:Data(stack.utf8)))
        }
        XCTAssertThrowsError(try DiagnosticCrash(recordedAt:Date(),stack:Data(repeating:32,count:1_048_577)))
        XCTAssertThrowsError(try DiagnosticReport(kind:.crash,appVersion:"1",build:"1",osVersion:"26",facts:facts))
        XCTAssertThrowsError(try DiagnosticReport(kind:.manual,appVersion:"https://private.invalid",build:"1",osVersion:"26",facts:facts))
    }
    func testManualBodyUsesAndroidContractWithoutAnInstallationOrAccessIdentity() throws {
        let first = try report(), second = try report()
        let fields = try JSONSerialization.jsonObject(with:first.body()) as! [String:String]
        XCTAssertEqual(Set(fields.keys),["log","version","device","app_version","iid"])
        XCTAssertEqual(fields["version"],"ios-manual"); XCTAssertEqual(fields["device"],"Apple iOS")
        XCTAssertEqual(fields["iid"],first.id); XCTAssertNotEqual(first.id,second.id)
        XCTAssertFalse(fields["log"]!.contains("server")); XCTAssertFalse(fields["log"]!.contains("userKey"))
        XCTAssertFalse(fields["log"]!.contains(first.id))
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticReport.self,from:JSONEncoder().encode(first)).id,first.id)
    }
    func testTransportUsesOnlyTrustedReportOriginAndNoCredentials() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiagnosticStub.self]
        let api = DiagnosticAPI(configuration:config)
        var count = 0
        DiagnosticStub.handler = { request in
            count += 1
            XCTAssertEqual(request.url?.absoluteString,"https://entrixy.com/api/crash_report.php")
            XCTAssertEqual(request.httpMethod,"POST"); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField:"Authorization")); XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
            return Data(#"{"ok":1}"#.utf8)
        }
        try await api.send(report()); XCTAssertEqual(count,1)
    }
    func testPrivacyBoundaryBlocksReportsBeforeAnyRequestEvenForAnExistingClient() async throws {
        enum Blocked: Error { case privacy }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiagnosticStub.self]
        let api = DiagnosticAPI(configuration:config)
        DiagnosticStub.handler = { _ in XCTFail("Report bypassed privacy"); return Data(#"{"ok":1}"#.utf8) }
        ServerSessionPolicy.shared.install({ _ in },authorize:{ _ in throw Blocked.privacy })
        do { try await api.send(report()); XCTFail("Expected privacy denial") } catch { XCTAssertTrue(error is Blocked) }
    }
}
