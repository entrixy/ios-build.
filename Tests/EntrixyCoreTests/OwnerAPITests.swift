import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EntrixyCore

private final class OwnerStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, bytes) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OwnerAPITests: XCTestCase {
    private let id = String(repeating: "a", count: 32)
    private let secret = String(repeating: "b", count: 64)
    override func tearDown() { OwnerStubProtocol.handler = nil; super.tearDown() }
    private func api() -> OwnerAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OwnerStubProtocol.self]
        return OwnerAPI(configuration: config)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n == 0 { break }
                guard n > 0 else { throw URLError(.cannotParseResponse) }
                data.append(contentsOf: buffer.prefix(n))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRegistrationMatchesAndroidAndOmitsLocalSecrets() async throws {
        OwnerStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://owner.invalid/api/register_host.php")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try self.body(request)
            XCTAssertEqual(body as? [String: String], ["access_code": "test-code"])
            return (200, try JSONSerialization.data(withJSONObject: ["device_id": self.id, "device_secret": self.secret]))
        }
        let credentials = try await api().register(server: "OWNER.invalid", accessCode: "test-code")
        XCTAssertEqual(credentials.deviceID, id)
        XCTAssertEqual(credentials.deviceSecret, secret)
    }

    func testLostRegistrationResponseIsNotRetried() async throws {
        var calls = 0
        OwnerStubProtocol.handler = { _ in calls += 1; throw URLError(.networkConnectionLost) }
        do { _ = try await api().register(server: "owner.invalid"); XCTFail("Must report uncertain registration") }
        catch {}
        XCTAssertEqual(calls, 1)
    }

    func testRedirectAndInvalidCredentialsAreRejected() async throws {
        for (status, data) in [(302, Data("{}".utf8)), (200, Data(#"{"device_id":"wrong","device_secret":"wrong"}"#.utf8))] {
            OwnerStubProtocol.handler = { _ in (status, data) }
            do { _ = try await api().register(server: "owner.invalid"); XCTFail("Invalid response accepted") }
            catch {}
        }
    }

    func testSyncSendsOwnerCredentialsAndFingerprintOnly() async throws {
        let fingerprint = String(repeating: "c", count: 64)
        OwnerStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/host_sync.php")
            XCTAssertEqual(try self.body(request) as? [String: String], ["device_id": self.id, "device_secret": self.secret, "device_fp": fingerprint])
            return (200, Data(#"{"numbers":[{"id":1,"type":"device"}],"keys":[{"id":2}]}"#.utf8))
        }
        let data = try await api().sync(server: "owner.invalid", credentials: OwnerCredentials(deviceID: id, deviceSecret: secret), fingerprint: fingerprint)
        XCTAssertEqual(try OwnerSnapshot.decode(data).objectCount, 1)
        XCTAssertEqual(try OwnerSnapshot.decode(data).guestKeyCount, 1)
    }

    func testInvalidSnapshotsCannotBecomeEmptySuccessfulSync() throws {
        for json in [#"{}"#, #"{"numbers":[],"keys":null}"#,
                     #"{"numbers":[{"id":true,"type":"device"}],"keys":[]}"#,
                     #"{"numbers":[{"id":1,"type":"unknown"}],"keys":[]}"#,
                     #"{"numbers":[],"keys":[{"id":1},{"id":1}]}"#] {
            XCTAssertThrowsError(try OwnerSnapshot.decode(Data(json.utf8)), json)
        }
    }

    func testPendingAccountRetainsMasterKeyAcrossSerialization() throws {
        let first = try OwnerAccount(server: "https://OWNER.invalid/")
        let second = try JSONDecoder().decode(OwnerAccount.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(first, second)
        XCTAssertTrue(second.registrationPending)
        XCTAssertEqual(second.masterKey.count, 32)
        try second.validate()
    }
    func testObjectMutationAuthenticatesWithoutLeakingWrappedKeys() async throws {
        let owner = try OwnerAccount(server: "owner.invalid")
        let object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота", kind: "call", phone: "+79990000000")
        OwnerStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/number_add.php")
            let body = try self.body(request)
            XCTAssertEqual(body["device_id"] as? String, self.id)
            XCTAssertEqual(body["device_secret"] as? String, self.secret)
            XCTAssertEqual(body["device_fp"] as? String, String(repeating: "c", count: 64))
            XCTAssertEqual(body["data_cipher"] as? String, object.cipher)
            XCTAssertNil(body["wrappedKey"])
            XCTAssertNil(body["masterKey"])
            XCTAssertNil(body["phone"])
            XCTAssertNil(body["label"])
            return (200, Data(#"{"id":7}"#.utf8))
        }
        _ = try await api().mutate(server: "owner.invalid", credentials: OwnerCredentials(deviceID: id, deviceSecret: secret), fingerprint: String(repeating: "c", count: 64), operation: .create, body: object.request())
    }

    func testMutationCannotOverrideInstallationAuthentication() async throws {
        var requests = 0
        OwnerStubProtocol.handler = { _ in requests += 1; return (200, Data("{}".utf8)) }
        do {
            _ = try await api().mutate(server: "owner.invalid", credentials: OwnerCredentials(deviceID: id, deviceSecret: secret), fingerprint: String(repeating: "c", count: 64), operation: .create, body: Data(#"{"device_id":"other"}"#.utf8))
            XCTFail("Protected authentication field accepted")
        } catch {}
        XCTAssertEqual(requests, 0)
    }

}
