import XCTest
import Network
import EntrixyCore
@testable import Entrixy

@MainActor private final class RTSPCameraFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "entrixy.test.rtsp")
    private var connections: [NWConnection] = []
    private var tasks: [Task<Void, Never>] = []
    private(set) var requests: [CameraRTSPMessage] = []
    private var ready: CheckedContinuation<URL, Error>?
    var reply: ((CameraRTSPMessage) throws -> Data)?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard let self else { return }
                if case .ready = state, let port = self.listener.port {
                    let pending = self.ready; self.ready = nil
                    pending?.resume(returning: URL(string: "rtsp://127.0.0.1:\(port.rawValue)/private/live")!)
                } else if case .failed(let error) = state { let pending = self.ready; self.ready = nil; pending?.resume(throwing: error) }
            } }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); tasks.forEach { $0.cancel() }; connections.forEach { $0.cancel() } }
    private func accept(_ connection: NWConnection) {
        connections.append(connection); connection.start(queue: queue)
        tasks.append(Task { [weak self] in
            var parser = CameraRTSPFramer()
            do {
                while !Task.isCancelled {
                    for frame in try parser.append(try await CameraSocket.read(connection)) {
                        if case .message(let message) = frame, let self {
                            requests.append(message)
                            if let response = try reply?(message) { try await CameraSocket.send(response, on: connection) }
                        }
                    }
                }
            } catch { connection.cancel() }
        })
    }
}

@MainActor final class CameraRTSPProxyTests: XCTestCase {
    private func proxy(_ camera: URL) throws -> CameraRTSPProxy {
        var config = ObjectCameraConfiguration(); config.enabled = true; config.url = camera.absoluteString
        config.authType = "basic"; config.authValue = "test-user:test-camera-password"
        return try CameraRTSPProxy(camera: CameraRequest(configuration: config))
    }
    private func client(_ url: URL) throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(try XCTUnwrap(url.port)))), using: .tcp)
        connection.start(queue: DispatchQueue(label: "entrixy.test.rtsp.client")); return connection
    }
    private func readMessage(_ connection: NWConnection) async throws -> CameraRTSPMessage {
        let timeout = Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if !Task.isCancelled { connection.cancel() } }
        defer { timeout.cancel() }; var parser = CameraRTSPFramer()
        while true { for frame in try parser.append(try await CameraSocket.read(connection)) { if case .message(let message) = frame { return message } } }
    }
    func testRTSPDigestUsesRemoteURIAndRewritesCameraSDPWithoutGivingCredentialsToDecoder() async throws {
        let fixture = try RTSPCameraFixture(); defer { fixture.stop() }
        let remote = try await fixture.start()
        fixture.reply = { message in
            XCTAssertEqual(message.request?.uri, remote.absoluteString)
            let cseq = try XCTUnwrap(message.headers["cseq"])
            if fixture.requests.count == 1 {
                XCTAssertEqual(cseq,"1")
                XCTAssertTrue(message.headers["authorization"]?.hasPrefix("Basic ") == true)
                return Data("RTSP/1.0 401 Unauthorized\r\nCSeq: \(cseq)\r\nWWW-Authenticate: Digest realm=\"camera\", nonce=\"test-nonce\", qop=\"auth\"\r\nContent-Length: 0\r\n\r\n".utf8)
            }
            let auth = try XCTUnwrap(message.headers["authorization"])
            XCTAssertEqual(cseq,"2","Authentication is a new upstream request, not a duplicate sequence")
            XCTAssertTrue(auth.hasPrefix("Digest ")); XCTAssertTrue(auth.contains("uri=\"" + remote.absoluteString + "\""))
            XCTAssertFalse(auth.contains("test-camera-password"))
            let sdp = "v=0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=control:trackID=1\r\n"
            return Data("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Base: \(remote.absoluteString)/\r\nContent-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n\(sdp)".utf8)
        }
        let bridge = try proxy(remote); defer { bridge.stop() }
        let local = try await bridge.start(), connection = try client(local); defer { connection.cancel() }
        XCTAssertFalse(local.absoluteString.contains("private")); XCTAssertFalse(local.absoluteString.contains("password"))
        try await CameraSocket.send(Data("DESCRIBE \(local.absoluteString) RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\n\r\n".utf8), on: connection)
        let response = try await readMessage(connection)
        XCTAssertEqual(response.status,200); XCTAssertEqual(response.headers["cseq"],"1"); XCTAssertEqual(fixture.requests.count,2)
        let sdp = String(decoding:response.body,as:UTF8.self)
        XCTAssertFalse(sdp.contains("trackID")); XCTAssertFalse(sdp.contains("private")); XCTAssertTrue(sdp.contains("a=control:rtsp://127.0.0.1:"))
        XCTAssertNil(response.headers["www-authenticate"])
    }
    func testRTSPRejectsDecoderRequestsForForeignOriginsBeforeSendingCameraCredentials() async throws {
        let fixture = try RTSPCameraFixture(); defer { fixture.stop() }
        let remote = try await fixture.start(), bridge = try proxy(remote); defer { bridge.stop() }
        let local = try await bridge.start(), connection = try client(local); defer { connection.cancel() }
        try await CameraSocket.send(Data("DESCRIBE rtsp://foreign.invalid/steal RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8), on: connection)
        do { _ = try await readMessage(connection); XCTFail("Foreign origin was accepted") } catch { }
        XCTAssertTrue(fixture.requests.isEmpty)
    }
}
