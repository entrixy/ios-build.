import XCTest
@testable import EntrixyCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class DeletionHTTPFixture: URLProtocol {
    static var requests: [URLRequest] = []
    static var result: DataDeletionResult?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "deletion.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Darwin URLSession hands URLProtocol a body stream; Linux may keep
        // httpBody. Record the actual bytes in either representation.
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating:0,count:4096)
            while true {
                let count = stream.read(&buffer,maxLength:buffer.count)
                guard count >= 0, body.count + count <= 65536 else { client?.urlProtocol(self,didFailWithError:URLError(.cannotDecodeRawData)); return }
                if count == 0 { break }; body.append(contentsOf:buffer.prefix(count))
            }
            recorded.httpBody = body
        }
        Self.requests.append(recorded)
        guard let result = Self.result else { client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse)); return }
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONEncoder().encode(result)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class DataDeletionTests: XCTestCase {
    func testReceiptAndStatusSurviveProtectedStateSerializationWithoutAnyPasswordOrAccountToken() throws {
        var receipt = DataDeletionReceipt(scope:.account)
        receipt.result = DataDeletionResult(requestID:receipt.id,scope:.account,status:.pending,requestedAt:1_700_000_000,expectedBy:1_700_086_400)
        try receipt.validate()
        var settings = OwnerServerSettings(); settings.deletionReceipt = receipt
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(OwnerServerSettings.self,from:data).deletionReceipt,receipt)
        XCTAssertNil(try JSONDecoder().decode(OwnerServerSettings.self,from:Data(#"{"accessCode":""}"#.utf8)).deletionReceipt)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(fields.keys),Set(["accessCode","deletionReceipt"]))
    }
    func testStatusCannotClaimDeletionUntilCompletionAndCannotChangeReceiptScope() throws {
        var receipt = DataDeletionReceipt(scope:.device)
        receipt.result = DataDeletionResult(requestID:receipt.id,scope:.device,status:.completed,requestedAt:100,expectedBy:200)
        XCTAssertThrowsError(try receipt.validate())
        receipt.result = DataDeletionResult(requestID:receipt.id,scope:.account,status:.pending,requestedAt:100,expectedBy:200)
        XCTAssertThrowsError(try receipt.validate())
        receipt.result = DataDeletionResult(requestID:receipt.id,scope:.device,status:.pending,requestedAt:100,expectedBy:200,completedAt:150)
        XCTAssertThrowsError(try receipt.validate())
    }
    func testRequestIsBoundToOwnerAndStatusUsesOnlyPrivateReceiptAfterCredentialsHaveBeenDeleted() async throws {
        let receipt = DataDeletionReceipt(scope:.account)
        let credentials = try OwnerCredentials(deviceID:String(repeating:"a",count:32),deviceSecret:String(repeating:"b",count:64))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeletionHTTPFixture.self]
        let api = OwnerAPI(configuration:config)
        DeletionHTTPFixture.requests = []
        DeletionHTTPFixture.result = DataDeletionResult(requestID:receipt.id,scope:receipt.scope,status:.pending,requestedAt:100,expectedBy:200)
        _ = try await api.dataDeletion(server:"deletion.invalid",credentials:credentials,receipt:receipt,accountToken:"temporary-account-token",submit:true)
        _ = try await api.dataDeletion(server:"deletion.invalid",credentials:credentials,receipt:receipt,accountToken:"must-not-send",submit:false)
        XCTAssertEqual(DeletionHTTPFixture.requests.count,2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(DeletionHTTPFixture.requests[0].httpBody)) as? [String:Any])
        XCTAssertEqual(first["device_secret"] as? String,credentials.deviceSecret); XCTAssertEqual(first["confirmation"] as? String,"DELETE")
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(DeletionHTTPFixture.requests[1].httpBody)) as? [String:Any])
        XCTAssertEqual(Set(second.keys),Set(["operation","request_id","receipt"]))
        XCTAssertEqual(DeletionHTTPFixture.requests[1].url?.path,"/api/data_deletion.php")
    }
}
