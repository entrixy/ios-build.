import XCTest
import EntrixyCore
@testable import Entrixy

private final class CameraVideoProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int,[String:String],Data))?
    private static var requests: [URLRequest] = []
    static func configure(_ handler: @escaping (URLRequest) throws -> (Int,[String:String],Data)) { lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = [] }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status,fields,bytes) = try handler(request)
            var headers = fields; headers["Content-Length"] = String(bytes.count)
            let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}

@MainActor final class CameraVideoProxyTests: XCTestCase {
    private func bridge(path: String) throws -> CameraVideoProxy {
        var config = ObjectCameraConfiguration(); config.enabled = true; config.url = "https://camera.invalid/" + path
        config.authType = "header"; config.authHeader = "X-Camera-Key"; config.authValue = "public-video-test-key"
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [CameraVideoProtocol.self]
        return try CameraVideoProxy(camera:CameraRequest(configuration:config),configuration:session)
    }
    private func get(_ url: URL,range: String? = nil) async throws -> (Data,HTTPURLResponse) {
        let settings = URLSessionConfiguration.ephemeral; settings.timeoutIntervalForRequest = 5
        let session = URLSession(configuration:settings); defer { session.invalidateAndCancel() }
        var request = URLRequest(url:url); request.setValue(range,forHTTPHeaderField:"Range")
        let (data,response) = try await session.data(for:request); return (data,try XCTUnwrap(response as? HTTPURLResponse))
    }
    func testAuthenticatedHLSUsesOpaqueLoopbackResourcesAndKeepsHeadersOnSameOriginSegments() async throws {
        CameraVideoProtocol.configure { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Camera-Key"),"public-video-test-key")
            XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
            if request.url?.path == "/live/index.m3u8" { return (200,["Content-Type":"application/vnd.apple.mpegurl"],Data("#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)) }
            XCTAssertEqual(request.url?.path,"/live/segment.ts")
            return (200,["Content-Type":"video/mp2t","Set-Cookie":"must-not-forward=1"],Data([1,2,3,4]))
        }
        let bridge = try bridge(path:"live/index.m3u8?private=source-token"); defer { bridge.stop() }
        let local = try await bridge.start()
        XCTAssertEqual(local.host,"127.0.0.1"); XCTAssertFalse(local.absoluteString.contains("camera.invalid")); XCTAssertFalse(local.absoluteString.contains("source-token"))
        let (playlist,response) = try await get(local); XCTAssertEqual(response.statusCode,200)
        let lines = String(decoding:playlist,as:UTF8.self).split(separator:"\n").filter { !$0.hasPrefix("#") }
        let segment = try XCTUnwrap(lines.first.flatMap { URL(string:String($0)) })
        XCTAssertEqual(segment.host,"127.0.0.1")
        let (bytes,mediaResponse) = try await get(segment)
        XCTAssertEqual(bytes,Data([1,2,3,4])); XCTAssertNil(mediaResponse.value(forHTTPHeaderField:"Set-Cookie"))
        XCTAssertEqual(CameraVideoProtocol.recorded().count,2)
    }
    func testAuthenticatedPlaylistCannotFetchForeignResourceAndUnknownLocalPathDoesNotFetchAnything() async throws {
        CameraVideoProtocol.configure { request in (200,["Content-Type":"application/vnd.apple.mpegurl"],Data("#EXTM3U\nhttps://foreign.invalid/steal.ts\n".utf8)) }
        let bridge = try bridge(path:"live/index.m3u8"); defer { bridge.stop() }
        let local = try await bridge.start()
        var wrong = URLComponents(url:local,resolvingAgainstBaseURL:false)!; wrong.path = "/wrong-session/file.m3u8"
        let (_,denied) = try await get(try XCTUnwrap(wrong.url)); XCTAssertEqual(denied.statusCode,404); XCTAssertTrue(CameraVideoProtocol.recorded().isEmpty)
        let (_,invalid) = try await get(local); XCTAssertEqual(invalid.statusCode,502)
        XCTAssertEqual(CameraVideoProtocol.recorded().map { $0.url?.host },["camera.invalid"])
    }
    func testDASHCapabilitiesExpandSegmentNumbersAndKeepAuthorizationAndQuerySecretInBridge() async throws {
        CameraVideoProtocol.configure { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Camera-Key"),"public-video-test-key")
            if request.url?.path == "/live/index.mpd" {
                return (200,["Content-Type":"application/dash+xml"],Data(#"<MPD><Period><AdaptationSet><Representation id="camera"><SegmentTemplate media="seg-$Number%05d$.m4s?secret=source-token" initialization="init.m4s?secret=source-token"/></Representation></AdaptationSet></Period></MPD>"#.utf8))
            }
            XCTAssertEqual(request.url?.path,"/live/seg-00017.m4s")
            XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"source-token")
            return (200,["Content-Type":"video/iso.segment"],Data([1,2,3,4]))
        }
        let bridge = try bridge(path:"live/index.mpd"); defer { bridge.stop() }
        let local = try await bridge.start()
        let (manifest,response) = try await get(local)
        XCTAssertEqual(response.statusCode,200); XCTAssertEqual(response.mimeType,"application/dash+xml")
        let xml = String(decoding:manifest,as:UTF8.self)
        XCTAssertFalse(xml.contains("source-token")); XCTAssertFalse(xml.contains("camera.invalid"))
        let regex = try NSRegularExpression(pattern:#"media="([^"]+)""#)
        let match = try XCTUnwrap(regex.firstMatch(in:xml,range:NSRange(xml.startIndex...,in:xml)))
        let range = try XCTUnwrap(Range(match.range(at:1),in:xml))
        let segment = try XCTUnwrap(URL(string:String(xml[range]).replacingOccurrences(of:"$Number%05d$",with:"00017")))
        let (bytes,segmentResponse) = try await get(segment)
        XCTAssertEqual(segmentResponse.statusCode,200); XCTAssertEqual(bytes,Data([1,2,3,4]))
        XCTAssertEqual(CameraVideoProtocol.recorded().count,2)
    }
    func testMP4RangeAndContentRangeArePreservedAndStopPreventsAnotherRemoteFetch() async throws {
        CameraVideoProtocol.configure { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"Range"),"bytes=0-3")
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Camera-Key"),"public-video-test-key")
            return (206,["Content-Type":"video/mp4","Content-Range":"bytes 0-3/40","Accept-Ranges":"bytes"],Data([0,1,2,3]))
        }
        let bridge = try bridge(path:"video.mp4"); defer { bridge.stop() }
        let local = try await bridge.start()
        let (bytes,response) = try await get(local,range:"bytes=0-3")
        XCTAssertEqual(bytes,Data([0,1,2,3])); XCTAssertEqual(response.statusCode,206); XCTAssertEqual(response.value(forHTTPHeaderField:"Content-Range"),"bytes 0-3/40")
        bridge.stop()
        do { _ = try await get(local,range:"bytes=0-3"); XCTFail("stopped bridge still accepts requests") } catch { }
        XCTAssertEqual(CameraVideoProtocol.recorded().count,1)
    }
    func testActualWebMDecoderDisplaysFramesThroughAuthenticatedHTTPBridge() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource:"camera-decoder",withExtension:"webm"))
        let video = try Data(contentsOf:url)
        CameraVideoProtocol.configure { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Camera-Key"),"public-video-test-key")
            return (200,["Content-Type":"video/webm"],video)
        }
        var camera = ObjectCameraConfiguration(); camera.enabled = true; camera.url = "https://camera.invalid/video.webm"
        camera.authType = "header"; camera.authHeader = "X-Camera-Key"; camera.authValue = "public-video-test-key"
        try await assertDecoded(camera)
    }
    func testActualDASHDecoderDisplaysFramesFromProtectedManifestAndSegments() async throws {
        let bundle = Bundle(for: Self.self)
        CameraVideoProtocol.configure { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Camera-Key"),"public-video-test-key")
            let name = try XCTUnwrap(request.url?.lastPathComponent)
            let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
            let resource = try XCTUnwrap(bundle.url(forResource:stem,withExtension:ext))
            return (200,["Content-Type":ext == "mpd" ? "application/dash+xml" : "video/mp4"],try Data(contentsOf:resource))
        }
        var camera = ObjectCameraConfiguration(); camera.enabled = true; camera.url = "https://camera.invalid/camera-decoder.mpd"
        camera.authType = "header"; camera.authHeader = "X-Camera-Key"; camera.authValue = "public-video-test-key"
        try await assertDecoded(camera)
        XCTAssertTrue(CameraVideoProtocol.recorded().contains { $0.url?.lastPathComponent == "dash-init-0.m4s" })
        XCTAssertTrue(CameraVideoProtocol.recorded().contains { $0.url?.lastPathComponent == "dash-seg-0-00001.m4s" })
    }
    private func assertDecoded(_ camera: ObjectCameraConfiguration) async throws {
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [CameraVideoProtocol.self]
        let model = CameraStreamModel(transport:CameraHTTPFrames(configuration:settings)); defer { model.stop() }
        model.start(ObjectCameraContext(configuration:camera,guestUserKey:nil,localKeyID:"0"))
        for _ in 0..<100 where model.softwareVideo == nil && model.message == nil { try await Task.sleep(nanoseconds:20_000_000) }
        let player = try XCTUnwrap(model.softwareVideo)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene:scene); window.rootViewController = UIViewController()
        window.frame = CGRect(x:0,y:0,width:160,height:120)
        window.rootViewController?.view.addSubview(player.view); player.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer { player.view.removeFromSuperview(); window.isHidden = true; previous?.makeKey() }
        for _ in 0..<250 where !player.hasDecodedVideo && model.message == nil { try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertTrue(player.hasDecodedVideo,"The extended decoder did not produce actual video output")
        XCTAssertNil(model.message); XCTAssertFalse(model.loading); XCTAssertFalse(CameraVideoProtocol.recorded().isEmpty)
        model.stop(); XCTAssertNil(model.softwareVideo)
    }
}
