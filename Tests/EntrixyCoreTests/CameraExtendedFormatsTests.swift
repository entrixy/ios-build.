import XCTest
@testable import EntrixyCore

final class CameraExtendedFormatsTests: XCTestCase {
    func testExplicitAuthorizationWinsCaseInsensitivelyOverURLUserInfo() throws {
        var configuration = ObjectCameraConfiguration(); configuration.enabled = true
        configuration.url = "rtsp://old-user:old-password@camera.invalid/live"
        configuration.authType = "header"; configuration.authHeader = "authorization"; configuration.authValue = "Bearer explicit-test-value"
        let camera = try CameraRequest(configuration:configuration)
        XCTAssertNil(camera.url.user); XCTAssertNil(camera.url.password)
        XCTAssertEqual(camera.headers.count,1); XCTAssertEqual(camera.headers["authorization"],"Bearer explicit-test-value")
    }
    func testDASHRewritesNestedBasesTemplatesSegmentsAndClockWithoutLeakingCredentials() throws {
        let xml = #"<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><BaseURL>media/</BaseURL><UTCTiming schemeIdUri="urn:mpeg:dash:utc:http-iso:2014" value="clock"/><Period><AdaptationSet bitstreamSwitching="true"><Representation id="one"><SegmentTemplate initialization="init-$RepresentationID$.m4s?token=secret" media="$RepresentationID$/seg-$Number%05d$.m4s?token=secret"/></Representation></AdaptationSet></Period></MPD>"#
        let base = URL(string: "https://camera.invalid/live/index.mpd")!
        var references: [URL] = []
        let result = try CameraDASHManifest.rewriting(Data(xml.utf8), base: base) { value, parent in
            let template = try CameraDASHTemplate(value, base: parent)
            references.append(try template.expanded(template.fields.map { $0.contains("RepresentationID") ? "one" : "00017" }))
            return "http://127.0.0.1:9999/cap/" + String(references.count)
        }
        let text = String(decoding: result, as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("camera.invalid"))
        XCTAssertTrue(text.contains("bitstreamSwitching=\"true\""))
        XCTAssertEqual(references.map(\.absoluteString), ["https://camera.invalid/live/media/", "https://camera.invalid/live/media/clock", "https://camera.invalid/live/media/init-one.m4s?token=secret", "https://camera.invalid/live/media/one/seg-00017.m4s?token=secret"])
    }
    func testDASHRejectsEntitiesForeignResourcesAndAuthoritySubstitutions() throws {
        let base = URL(string: "https://camera.invalid/live.mpd")!
        for text in [#"<!DOCTYPE MPD [<!ENTITY a SYSTEM "file:///etc/passwd">]><MPD>&a;</MPD>"#, #"<MPD><Period xlink:href="https://foreign.invalid"/></MPD>"#, #"<MPD><ContentSteering>https://foreign.invalid/</ContentSteering></MPD>"#, #"<MPD><UTCTiming schemeIdUri="urn:mpeg:dash:utc:ntp:2014" value="foreign.invalid"/></MPD>"#] {
            XCTAssertThrowsError(try CameraDASHManifest.rewriting(Data(text.utf8), base: base) { _, _ in "unused" })
        }
        XCTAssertThrowsError(try CameraDASHTemplate("https://$RepresentationID$/steal.m4s", base: base))
        let template = try CameraDASHTemplate("seg-$Number$.m4s", base: base)
        XCTAssertEqual(try CameraDASHTemplate("price-$$-$Number$.m4s",base:base).expanded(["1"]).absoluteString,"https://camera.invalid/price-%24-1.m4s")
        for value in ["../steal", "https://foreign.invalid", "%2f", "", ".."] { XCTAssertThrowsError(try template.expanded([value])) }
        XCTAssertThrowsError(try CameraDASHManifest.rewriting(Data(#"<MPD><BaseURL>https://foreign.invalid/</BaseURL></MPD>"#.utf8), base: base) { value, parent in
            let url = try CameraDASHTemplate(value, base: parent).expanded([])
            guard url.host == base.host else { throw GuestCrypto.Failure.invalidEnvelope }; return "http://127.0.0.1/cap"
        })
    }
    func testRTSPFramingPreservesFragmentedBinaryPacketsAndRejectsSmuggling() throws {
        let response = Data("RTSP/1.0 200 OK\r\nCSeq: 9\r\nContent-Length: 3\r\n\r\nsdp".utf8)
        let packet = Data([36,0,0,4,13,10,36,0])
        var parser = CameraRTSPFramer(), frames: [CameraRTSPFramer.Frame] = []
        for byte in response + packet { frames += try parser.append(Data([byte])) }
        XCTAssertEqual(frames.count,2)
        if case .message(let message) = frames[0] { XCTAssertEqual(message.body,Data("sdp".utf8)); XCTAssertEqual(message.status,200) } else { XCTFail() }
        if case .packet(let actual) = frames[1] { XCTAssertEqual(actual,packet) } else { XCTFail() }
        for raw in ["RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: -1\r\n\r\n", "RTSP/1.0 200 OK\r\nCSeq: 1\r\nCSeq: 2\r\n\r\n", "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 1048577\r\n\r\n"] {
            XCTAssertThrowsError(try CameraRTSPMessage(header:Data(raw.utf8)))
        }
        let request = try CameraRTSPMessage(header:Data("ANNOUNCE rtsp://camera.invalid/live RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8))
        XCTAssertNil(request.request)
    }
    func testRTSPDigestMatchesRFC2617VectorAndRejectsUnsupportedChallenges() throws {
        let digest = try CameraRTSPDigest(challenge: #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#)
        let basic = "Basic " + Data("Mufasa:Circle Of Life".utf8).base64EncodedString()
        let authorization = try digest.authorization(basic:basic,method:"GET",uri:"/dir/index.html",count:1,cnonce:"0a4f113b")
        XCTAssertTrue(authorization.contains("6629fae49393a05397450978507c4ef1"))
        XCTAssertFalse(authorization.contains("Circle Of Life")); XCTAssertTrue(authorization.contains("nc=00000001"))
        for challenge in [#"Digest realm="x", nonce="y", qop="auth-int""#, #"Digest realm="x", nonce="y", algorithm=unknown"#, #"Digest realm="x", nonce="y", nonce="z""#] { XCTAssertThrowsError(try CameraRTSPDigest(challenge:challenge)) }
    }
    func testAppHelloMatchesWorkingServerClassificationAndRetainsAuthentication() throws {
        let userKey = GuestCrypto.base64URL(Data(repeating:17,count:32)), fp = String(repeating:"a",count:64)
        let hello = try GuestCrypto.hello(userKey:userKey,fingerprint:fp,timestamp:42,nonce:String(repeating:"b",count:32))
        XCTAssertEqual(hello["client"],"app"); XCTAssertEqual(hello["suite"],"v1")
        let material = "v1.\(GuestCrypto.hash(Data(userKey.utf8))).42.\(String(repeating:"b",count:32)).guest_hello.\(GuestCrypto.hash(Data(fp.utf8)))"
        XCTAssertTrue(try GuestCrypto.verify(signature:XCTUnwrap(Data(base64Encoded:hello["sig"]!)),material:Data(material.utf8),publicKey:GuestCrypto.signingKey(userKey:userKey,deviceFingerprint:fp).publicKey.rawRepresentation))
    }
}
