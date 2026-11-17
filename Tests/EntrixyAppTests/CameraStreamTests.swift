import XCTest
import EntrixyCore
@testable import Entrixy

private final class CameraFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: (Int,String,Data) = (200,"image/png",Data())
    private static var requests: [URLRequest] = []
    static func configure(status: Int = 200, mime: String = "image/png", body: Data) {
        lock.lock(); defer { lock.unlock() }
        response = (status,mime,body); requests = []
    }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "camera.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let response = Self.response; Self.requests.append(request); Self.lock.unlock()
        let http = HTTPURLResponse(url:request.url!,statusCode:response.0,httpVersion:"HTTP/1.1",headerFields:["Content-Type":response.1])!
        client?.urlProtocol(self,didReceive:http,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:response.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor final class CameraStreamTests: XCTestCase {
    private let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC")!
    private func transport() -> CameraHTTPFrames {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CameraFixtureProtocol.self]
        return CameraHTTPFrames(configuration:configuration)
    }
    private func camera() -> ObjectCameraConfiguration {
        var camera = ObjectCameraConfiguration(); camera.enabled = true; camera.intervalSec = 0
        camera.url = "https://camera.invalid/frame.png?ts={ts}"; return camera
    }
    func testSnapshotUsesScopedAuthorizationAndDeliversActualBytes() async throws {
        CameraFixtureProtocol.configure(body:png)
        var config = camera(); config.authType = "header"; config.authHeader = "X-Camera-Key"; config.authValue = "public-test-value"
        var frames: [Data] = []
        try await transport().load(CameraRequest(configuration:config)) { frames.append($0) }
        XCTAssertEqual(frames,[png])
        XCTAssertEqual(CameraFixtureProtocol.recorded().first?.value(forHTTPHeaderField:"X-Camera-Key"),"public-test-value")
        XCTAssertNil(CameraFixtureProtocol.recorded().first?.value(forHTTPHeaderField:"Cookie"))
    }
    func testHTTPFailureNeverAppearsAsAnImage() async throws {
        CameraFixtureProtocol.configure(status:403,mime:"text/html",body:Data("forbidden".utf8))
        do {
            try await transport().load(CameraRequest(configuration:camera())) { _ in XCTFail("Denied body must not become a frame") }
            XCTFail("403 must fail")
        } catch CameraStreamFailure.http(let status) { XCTAssertEqual(status,403) }
    }
    func testMultipartDeliversFramesInsteadOfTheHTTPMultipartEnvelope() async throws {
        let one = Data([0xff,0xd8,0xff,0xda,0,2,1,0xff,0xd9])
        let two = Data([0xff,0xd8,0xff,0xda,0,2,2,0xff,0xd9])
        let header = Data("--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        CameraFixtureProtocol.configure(mime:"multipart/x-mixed-replace; boundary=frame",body:header+one+Data("\r\n".utf8)+header+two)
        var frames: [Data] = []
        try await transport().load(CameraRequest(configuration:camera())) { frames.append($0) }
        XCTAssertEqual(frames,[one,two])
    }
    func testModelDecodesImageAndReportsInvalidBodyInsteadOfAnEndlessLoader() async throws {
        CameraFixtureProtocol.configure(body:png)
        let model = CameraStreamModel(transport:transport())
        model.start(ObjectCameraContext(configuration:camera(),guestUserKey:nil,localKeyID:"0"))
        for _ in 0..<300 where model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertNotNil(model.image); XCTAssertNil(model.message); XCTAssertFalse(model.loading)
        model.stop()
        CameraFixtureProtocol.configure(mime:"text/html",body:Data("not an image".utf8))
        model.start(ObjectCameraContext(configuration:camera(),guestUserKey:nil,localKeyID:"0"))
        for _ in 0..<300 where model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertNil(model.image); XCTAssertNotNil(model.message); XCTAssertFalse(model.loading)
        model.stop()
    }
}
