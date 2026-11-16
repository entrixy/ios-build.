import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EntrixyCore

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GuestAPITests: XCTestCase {
    private func api() -> GuestAPI {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return GuestAPI(configuration: c)
    }
    private func invite() throws -> GuestInvite {
        try GuestInvite.parse("AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
    }
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }

    func testBundleDepthHintIsPreservedWithoutChangingCiphertextAndRejectsInvalidTypes() async throws {
        let link = try invite()
        let payload = Data("{}".utf8)
        let cipher = try GuestCrypto.encrypt(key: link.bundleKey, plaintext: payload)
        for depth in [0, 1, 5] {
            StubProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["bundle_cipher": cipher, "delegate_depth": depth])) }
            let reply = try await api().bundleWithDepth(invite: link, fingerprint: "test")
            XCTAssertEqual(reply.depth, depth); XCTAssertEqual(reply.contents, payload)
        }
        for invalid in [true, -1, 6, 1.5, "1"] as [Any] {
            StubProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["bundle_cipher": cipher, "delegate_depth": invalid])) }
            do { _ = try await api().bundleWithDepth(invite: link, fingerprint: "test"); XCTFail("Invalid depth accepted") }
            catch { XCTAssertEqual((error as? GuestAPI.Failure)?.code, "invalid_delegate_depth") }
        }
        StubProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["bundle_cipher": cipher])) }
        let legacy = try await api().bundleWithDepth(invite: link, fingerprint: "test")
        XCTAssertEqual(legacy.depth, 0)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotParseResponse) }
            if count == 0 { return bytes }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    func testDeviceBindingFallsBackOnlyForBadKey() async throws {
        let invite = try invite(), fp = String(repeating: "f", count: 64)
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            XCTAssertEqual(request.url?.path, "/api/key_bind.php")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Entrixy-Sig"))
            if count == 1 { return (403, Data("{\"error\":\"bad_key\"}".utf8)) }
            return (200, Data("{\"ok\":1,\"device_key\":true}".utf8))
        }
        try await api().bind(invite: invite, fingerprint: fp)
        XCTAssertEqual(count, 2)
    }

    func testOtherDeviceBindingIsNotRetriedAsInvitation() async throws {
        var count = 0
        StubProtocol.handler = { _ in count += 1; return (403, Data("{\"error\":\"already_bound\"}".utf8)) }
        do {
            try await api().bind(invite: invite(), fingerprint: String(repeating: "f", count: 64))
            XCTFail("Binding must be refused")
        } catch let failure as GuestAPI.Failure { XCTAssertEqual(failure.code, "already_bound") }
        XCTAssertEqual(count, 1)
    }

    func testLostBindResponseIsNotAutomaticallyRepeated() async throws {
        var count = 0
        StubProtocol.handler = { _ in count += 1; throw URLError(.networkConnectionLost) }
        do {
            try await api().bind(invite: invite(), fingerprint: String(repeating: "f", count: 64))
            XCTFail("Transport failure must be propagated")
        } catch { XCTAssertFalse(error is GuestAPI.Failure) }
        XCTAssertEqual(count, 1)
    }

    func testNativeOnlyBundleIsDecryptedWithoutAppSecret() async throws {
        let invite = try invite()
        let clear = Data("{\"welcome\":\"Hello\"}".utf8)
        let cipher = try GuestCrypto.encrypt(key: invite.bundleKey, plaintext: clear)
        let response = try JSONSerialization.data(withJSONObject: ["native_only": true, "bundle_cipher": cipher])
        StubProtocol.handler = { _ in (200, response) }
        let result = try await api().bundle(invite: invite, fingerprint: String(repeating: "f", count: 64))
        XCTAssertEqual(result, clear)
    }

    func testRedirectStatusDoesNotCountAsSuccess() async throws {
        StubProtocol.handler = { _ in (302, Data("{}".utf8)) }
        do {
            _ = try await api().post(invite: invite(), fingerprint: String(repeating: "f", count: 64), endpoint: "key_bundle", body: Data("{}".utf8))
            XCTFail("Redirect must not be accepted")
        } catch let failure as GuestAPI.Failure { XCTAssertEqual(failure.status, 302) }
    }
    func testTransportSignsExactBodyAndDoesNotTransmitInvitationSecret() async throws {
        let invite = try invite(), fp = String(repeating: "f", count: 64)
        let body = Data("{ \"second\": 2, \"first\": 1 }".utf8)
        StubProtocol.handler = { request in
            let transmitted = try self.requestBody(request)
            XCTAssertEqual(transmitted, body)
            XCTAssertFalse(String(decoding: transmitted, as: UTF8.self).contains(invite.userKey))
            let id = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Key"))
            let ts = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Ts"))
            let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Nonce"))
            let sig = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Sig"))))
            let material = "v1.\(id).\(ts).\(nonce).key_bundle.\(GuestCrypto.hash(body))"
            let publicKey = try GuestCrypto.signingKey(userKey: invite.userKey, deviceFingerprint: fp).publicKey
            XCTAssertTrue(publicKey.isValidSignature(sig, for: Data(material.utf8)))
            return (200, Data("{}".utf8))
        }
        _ = try await api().post(invite: invite, fingerprint: fp, endpoint: "key_bundle", body: body)
    }

    func testRedirectDelegateNeverForwardsAuthenticatedRequest() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: "https://keys.example.org/api/key_bundle.php"))
        let other = try XCTUnwrap(URL(string: "https://other.example.org/api/key_bundle.php"))
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: ["Location": other.absoluteString]))
        var called = false
        NoRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: other)) { result in
            called = true
            XCTAssertNil(result)
        }
        XCTAssertTrue(called)
    }

    func testSigningOnlyMigrationCanWaitForAndRecoverOwnerSealedBundle() async throws {
        let identity = try GuestSigningIdentity(server: "https://owner.invalid", userKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX")
        let recipient = BundleKeySeal.makeRecipient(), key = Data(repeating: 7, count: 32)
        let fingerprint = String(repeating: "b", count: 64)
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            let body = try self.requestBody(request)
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(identity.userKey))
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(recipient.privateKey))
            if request.url?.path == "/api/key_bind.php" { return (200, Data(#"{"ok":1,"device_key":true}"#.utf8)) }
            XCTAssertEqual(request.url?.path, "/api/key_bundle.php")
            XCTAssertEqual(body, Data("{}".utf8))
            return (200, Data(#"{"bundle_cipher":null,"key_cipher":null}"#.utf8))
        }
        let transport = api()
        try await transport.move(identity: identity, oldFingerprint: String(repeating: "a", count: 64), newFingerprint: fingerprint)
        let waiting = try await transport.recover(identity: identity, bundleKey: nil, recipient: recipient, fingerprint: fingerprint)
        XCTAssertNil(waiting); XCTAssertEqual(requests, 2)
        let sealed = try BundleKeySeal.seal(key, recipientPublicKey: recipient.publicKey)
        let cipher = try GuestCrypto.encrypt(key: key, plaintext: Data(#"{"ble":[],"welcome":"Готово"}"#.utf8))
        StubProtocol.handler = { request in
            XCTAssertEqual(try self.requestBody(request), Data("{}".utf8))
            return (200, try JSONSerialization.data(withJSONObject: ["bundle_cipher": cipher, "key_cipher": sealed]))
        }
        let recovered = try await transport.recover(identity: identity, bundleKey: nil, recipient: recipient, fingerprint: fingerprint)
        XCTAssertEqual(recovered?.bundleKey, key); XCTAssertEqual(recovered?.userKey, identity.userKey)
        XCTAssertEqual(recovered?.server, identity.server)
        do {
            _ = try await transport.recover(identity: identity, bundleKey: key, recipient: BundleKeySeal.makeRecipient(), fingerprint: fingerprint)
            XCTFail("A wrong recipient must not silently fall back to an old bundle key")
        } catch {}
    }
    func testSigningIdentityRejectsInvalidDecodedStateAndNeverRetriesMigrationCooldown() async throws {
        XCTAssertThrowsError(try JSONDecoder().decode(GuestSigningIdentity.self, from: Data(#"{"server":"http://bad.invalid","userKey":"bad"}"#.utf8)))
        let identity = try GuestSigningIdentity(invite())
        var requests = 0
        StubProtocol.handler = { _ in requests += 1; return (429, Data(#"{"error":"move_too_soon"}"#.utf8)) }
        do {
            try await api().move(identity: identity, oldFingerprint: String(repeating: "a", count: 64), newFingerprint: String(repeating: "b", count: 64))
            XCTFail("Cooldown must remain a refusal")
        } catch let error as GuestAPI.Failure { XCTAssertEqual(error.code, "move_too_soon") }
        XCTAssertEqual(requests, 1)
    }

    func testMigrationUsesNewPairForIdempotentRecoveryThenTheOldDeviceProof() async throws {
        let invite = try invite(), old = String(repeating: "a", count: 64), new = String(repeating: "b", count: 64)
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            let body = try self.requestBody(request)
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["device_fp"] as? String, new)
            XCTAssertEqual(json["device_pub"] as? String, try GuestCrypto.devicePublicKey(userKey: invite.userKey, fingerprint: new))
            XCTAssertEqual(json["move"] as? Int, 1)
            if requests == 1 { return (403, Data(#"{"error":"bad_key"}"#.utf8)) }
            return (200, Data(#"{"ok":1,"device_key":true,"bound":"moved"}"#.utf8))
        }
        try await api().move(invite: invite, oldFingerprint: old, newFingerprint: new)
        XCTAssertEqual(requests, 2)
        requests = 0
        StubProtocol.handler = { _ in requests += 1; return (200, Data(#"{"ok":1,"device_key":true,"bound":"same"}"#.utf8)) }
        try await api().move(invite: invite, oldFingerprint: old, newFingerprint: new)
        XCTAssertEqual(requests, 1)
    }

    func testMigrationRefusalIsNeverRetriedAsAnInvitation() async throws {
        var requests = 0
        StubProtocol.handler = { _ in requests += 1; return (429, Data(#"{"error":"move_too_soon"}"#.utf8)) }
        do {
            try await api().move(invite: invite(), oldFingerprint: String(repeating:"a",count:64), newFingerprint: String(repeating:"b",count:64))
            XCTFail("Cooldown must block migration")
        } catch let failure as GuestAPI.Failure { XCTAssertEqual(failure.code, "move_too_soon") }
        XCTAssertEqual(requests, 1)
    }

    func testDelegationQueryUsesCanonicalEndpointAndExactSignedBody() async throws {
        let invite = try invite(), fp = String(repeating: "f", count: 64)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/key_delegate.php")
            XCTAssertEqual(request.url?.query, "a=create")
            let body = try self.requestBody(request)
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["device_fp"] as? String, fp)
            let id = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Key"))
            let ts = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Ts"))
            let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Nonce"))
            let sig = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Entrixy-Sig"))))
            let material = "v1.\(id).\(ts).\(nonce).key_delegate.\(GuestCrypto.hash(body))"
            XCTAssertTrue(try GuestCrypto.verify(signature: sig, material: Data(material.utf8), publicKey: GuestCrypto.signingKey(userKey: invite.userKey, deviceFingerprint: fp).publicKey.rawRepresentation))
            return (200, Data("{}".utf8))
        }
        _ = try await api().delegate(invite: invite, fingerprint: fp, operation: .create, body: Data(#"{"objects":[{"id":7,"depth":0,"pool":1}],"device_fp":"untrusted"}"#.utf8))
    }
    func testPublicRedemptionNeverTransmitsRecipientPrivateMaterialOrFragmentSecret() async throws {
        let link = try DelegationLink(server: "controller.invalid", group: String(repeating: "A", count: 22), secret: Data(repeating: 9, count: 32))
        let info = try JSONSerialization.data(withJSONObject: ["grp": link.group, "state": "new", "parts": [["code": String(repeating: "B", count: 22), "state": "new"]]])
        let pending = try DelegationRedemption(link: link, info: info)
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.query, "a=redeem")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Entrixy-Key"))
            let text = String(decoding: try self.requestBody(request), as: UTF8.self)
            for secret in [GuestCrypto.base64URL(link.secret), pending.recipient.privateKey, pending.parts[0].userKey] { XCTAssertFalse(text.contains(secret)) }
            throw URLError(.networkConnectionLost)
        }
        do { _ = try await api().redeemDelegation(pending, fingerprint: String(repeating: "a", count: 64)); XCTFail("Lost reply must be propagated") }
        catch { XCTAssertEqual(calls, 1) }
    }

    func testDelegatedBundleIsAcceptedOnlyForThePersistedRecipient() async throws {
        let link = try DelegationLink(server: "controller.invalid", group: String(repeating: "A", count: 22), secret: Data(repeating: 9, count: 32))
        let info = try JSONSerialization.data(withJSONObject: ["grp": link.group, "state": "new", "parts": [["code": String(repeating: "B", count: 22), "state": "new"]]])
        var pending = try DelegationRedemption(link: link, info: info)
        pending.sent = true
        let key = Data(repeating: 27, count: 32), fp = String(repeating: "a", count: 64)
        let cipher = try GuestCrypto.encrypt(key: key, plaintext: Data(#"{"obj_keys":{},"templates":{}}"#.utf8))
        var wrongRecipient = true
        StubProtocol.handler = { request in
            if request.url?.path == "/api/key_bind.php" { return (200, Data(#"{"ok":1,"device_key":true}"#.utf8)) }
            XCTAssertEqual(request.url?.path, "/api/key_bundle.php")
            let sealed = try BundleKeySeal.seal(key, recipientPublicKey: wrongRecipient ? BundleKeySeal.makeRecipient().publicKey : pending.recipient.publicKey)
            return (200, try JSONSerialization.data(withJSONObject: ["key_cipher": sealed, "bundle_cipher": cipher]))
        }
        do { _ = try await api().resolveDelegation(pending, part: pending.parts[0], fingerprint: fp); XCTFail("A server substitute must fail") } catch { }
        wrongRecipient = false
        let invite = try await api().resolveDelegation(pending, part: pending.parts[0], fingerprint: fp)
        XCTAssertEqual(invite?.bundleKey, key)
        XCTAssertEqual(invite?.userKey, pending.parts[0].userKey)
    }

    func testMessageAcknowledgementUsesTheExactCipherHashAndDoesNotFallBackOrRetry() async throws {
        let invite = try invite(), fp = String(repeating: "f", count: 64), hash = GuestMessageCrypto.acknowledgementHash("v1:test")
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/api/message_ack.php")
            let row = try JSONSerialization.jsonObject(with: self.requestBody(request)) as! [String: String]
            XCTAssertEqual(row, ["kind": "read", "h": hash])
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Entrixy-Sig"))
            throw URLError(.networkConnectionLost)
        }
        do { try await api().acknowledgeMessage(invite: invite, fingerprint: fp, kind: .read, hash: hash); XCTFail("Lost acknowledgement must be propagated") }
        catch { XCTAssertEqual(calls, 1) }
        do { try await api().acknowledgeMessage(invite: invite, fingerprint: fp, kind: .read, hash: "invalid"); XCTFail("Invalid hash must never be transmitted") }
        catch { XCTAssertEqual(calls, 1) }
    }

}
