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
}
