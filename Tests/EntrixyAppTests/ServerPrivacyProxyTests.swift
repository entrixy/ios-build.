import XCTest
import Network
import EntrixyCore
@testable import Entrixy

@MainActor private final class PrivacyTestSocket {
    let connection: NWConnection
    private var ready = false
    private var waiting: CheckedContinuation<Void,Error>?
    private var deadline: Task<Void,Never>?
    init(port: UInt16) {
        connection = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
        connection.stateUpdateHandler = { [weak self] state in Task { @MainActor in
            guard let self else { return }
            switch state {
            case .ready: self.ready = true; let pending = self.waiting; self.waiting = nil; pending?.resume()
            case .failed(let error): let pending = self.waiting; self.waiting = nil; pending?.resume(throwing:error)
            case .cancelled: let pending = self.waiting; self.waiting = nil; pending?.resume(throwing:CancellationError())
            default: break
            }
        } }
        connection.start(queue:.main)
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { return }
            self?.connection.cancel()
        }
    }
    func open() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() { deadline?.cancel(); connection.cancel() }
    func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void,Error>) in
            connection.send(content:bytes,completion:.contentProcessed { error in
                if let error { pending.resume(throwing:error) } else { pending.resume() }
            })
        }
    }
    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { pending in
            connection.receive(minimumIncompleteLength:1,maximumLength:32768) { bytes,_,_,error in
                if let error { pending.resume(throwing:error) } else { pending.resume(returning:bytes ?? Data()) }
            }
        }
    }
    func response() async throws -> Data {
        var bytes = Data()
        while bytes.range(of:Data("\r\n\r\n".utf8)) == nil {
            let part = try await read(); guard !part.isEmpty,bytes.count < 65536 else { throw URLError(.cannotParseResponse) }
            bytes.append(part)
        }
        return bytes
    }
}

@MainActor private final class PrivacyEchoServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var readiness: CheckedContinuation<UInt16,Error>?
    private(set) var received = Data()
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener = try NWListener(using:parameters,on:.any)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { pending in
            readiness = pending
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: let value = self.readiness; self.readiness = nil; value?.resume(returning:self.listener.port!.rawValue)
                case .failed(let error): let value = self.readiness; self.readiness = nil; value?.resume(throwing:error)
                default: break
                }
            } }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection); connection.start(queue:.main); self.read(connection)
            } }
            listener.start(queue:.main)
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength:1,maximumLength:32768) { [weak self] data,_,done,error in Task { @MainActor in
            guard let self else { return }
            if let data,!data.isEmpty {
                self.received.append(data)
                connection.send(content:data,completion:.contentProcessed { _ in })
            }
            if done || error != nil { connection.send(content:nil,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed { _ in }) }
            else { self.read(connection) }
        } }
    }
}

@MainActor final class ServerPrivacyProxyTests: XCTestCase {
    private func header(_ address: ServerPrivacyProxy.Address,auth: String? = nil) -> Data {
        Data("CONNECT server.invalid:443 HTTP/1.1\r\nHost: server.invalid:443\r\nProxy-Authorization: \(auth ?? address.authorization)\r\n\r\n".utf8)
    }
    func testAuthenticatedTunnelForwardsOpaqueBytesAndLeavesTheirContentUntouched() async throws {
        let echo = try PrivacyEchoServer(), port = try await echo.start(); defer { echo.stop() }
        var routes: [ServerNetworkRoute] = []
        let proxy = try ServerPrivacyProxy(decide:{ _ in .cellular },connect:{ host,targetPort,route in
            XCTAssertEqual(host,"server.invalid"); XCTAssertEqual(targetPort,443); routes.append(route)
            return NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
        }); defer { proxy.stop() }
        let address = try await proxy.start(), socket = PrivacyTestSocket(port:address.port); defer { socket.close() }
        try await socket.open()
        let opaque = Data([0x16,0x03,0x03,0xff,0,1,2,3])
        try await socket.send(header(address)+opaque)
        var response = try await socket.response()
        let boundary = try XCTUnwrap(response.range(of:Data("\r\n\r\n".utf8)))
        XCTAssertTrue(String(decoding:response[..<boundary.lowerBound],as:UTF8.self).contains("200 Connection Established"))
        response = Data(response[boundary.upperBound...])
        while response.count < opaque.count {
            let part = try await socket.read()
            guard !part.isEmpty else { throw URLError(.networkConnectionLost) }
            response.append(part)
        }
        XCTAssertEqual(response,opaque); XCTAssertEqual(echo.received,opaque); XCTAssertEqual(routes,[.cellular])
    }
    func testMissingCapabilityAndBlockedPolicyNeverCreateAnUpstreamConnection() async throws {
        for blocked in [false,true] {
            var attempts = 0
            let proxy = try ServerPrivacyProxy(decide:{ _ in blocked ? .blocked : .system },connect:{ _,_,_ in
                attempts += 1
                return NWConnection(host:"127.0.0.1",port:1,using:.tcp)
            }); defer { proxy.stop() }
            let address = try await proxy.start(), socket = PrivacyTestSocket(port:address.port); defer { socket.close() }
            try await socket.open(); try await socket.send(header(address,auth:blocked ? nil : "Basic wrong-capability"))
            let response = String(decoding:try await socket.response(),as:UTF8.self)
            XCTAssertTrue(response.hasPrefix(blocked ? "HTTP/1.1 503" : "HTTP/1.1 407"))
            XCTAssertEqual(attempts,0)
        }
    }
    func testTighteningPrivacyClosesAnAlreadyOpenDefaultInterfaceTunnel() async throws {
        let echo = try PrivacyEchoServer(), port = try await echo.start(); defer { echo.stop() }
        let proxy = try ServerPrivacyProxy(decide:{ _ in .system },connect:{ _,_,_ in
            NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
        }); defer { proxy.stop() }
        let address = try await proxy.start(), socket = PrivacyTestSocket(port:address.port); defer { socket.close() }
        try await socket.open(); try await socket.send(header(address)); _ = try await socket.response()
        proxy.restrict(to:.cellular)
        do { let remaining = try await socket.read(); XCTAssertTrue(remaining.isEmpty) } catch { }
    }
    func testCellularFailureDoesNotTryTheSystemInterfaceAsFallback() async throws {
        var routes: [ServerNetworkRoute] = []
        let proxy = try ServerPrivacyProxy(decide:{ _ in .cellular },connect:{ _,_,route in
            routes.append(route); return NWConnection(host:"127.0.0.1",port:1,using:.tcp)
        }); defer { proxy.stop() }
        let address = try await proxy.start(), socket = PrivacyTestSocket(port:address.port); defer { socket.close() }
        try await socket.open(); try await socket.send(header(address))
        let response = try await socket.response()
        XCTAssertTrue(String(decoding:response,as:UTF8.self).hasPrefix("HTTP/1.1 502"))
        XCTAssertEqual(routes,[.cellular])
    }
    func testPublicURLSessionProxyConfigurationAuthenticatesBeforeTLSAndKeepsTLSValidation() async throws {
        guard #available(iOS 17.0,*) else { throw XCTSkip("Public proxy configuration requires iOS17") }
        let echo = try PrivacyEchoServer(), port = try await echo.start(); defer { echo.stop() }
        var attempts = 0
        let proxy = try ServerPrivacyProxy(decide:{ _ in .system },connect:{ _,_,_ in
            attempts += 1; return NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
        }); defer { proxy.stop() }
        let address = try await proxy.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 5
        address.configure(configuration)
        let session = URLSession(configuration:configuration); defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from:URL(string:"https://server.invalid/private")!)
            XCTFail("Echo server is not a valid TLS peer")
        } catch { }
        XCTAssertGreaterThan(attempts,0,proxy.rejectedHeaderShapeForTesting ?? "No rejected HTTP header")
        XCTAssertFalse(echo.received.isEmpty)
        XCTAssertNotEqual(String(data:echo.received,encoding:.utf8)?.contains("GET /private"),true)
    }
    func testWebSocketAlsoUsesTheAuthenticatedProxyAndRetainsTLSValidation() async throws {
        guard #available(iOS 17.0,*) else { throw XCTSkip("Public proxy configuration requires iOS17") }
        let echo = try PrivacyEchoServer(), port = try await echo.start(); defer { echo.stop() }
        var attempts = 0
        let proxy = try ServerPrivacyProxy(decide:{ _ in .cellular },connect:{ _,_,route in
            XCTAssertEqual(route,.cellular); attempts += 1
            return NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
        }); defer { proxy.stop() }
        let address = try await proxy.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 5
        address.configure(configuration)
        let session = URLSession(configuration:configuration); defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with:URLRequest(url:URL(string:"wss://server.invalid/socket")!,timeoutInterval:5))
        defer { socket.cancel(with:.goingAway,reason:nil) }
        socket.resume()
        do { _ = try await socket.receive(); XCTFail("The echo server is not a valid TLS/WebSocket peer") } catch { }
        XCTAssertGreaterThan(attempts,0,proxy.rejectedHeaderShapeForTesting ?? "No rejected HTTP header")
        XCTAssertFalse(echo.received.isEmpty)
        XCTAssertNotEqual(String(data:echo.received,encoding:.utf8)?.contains("GET /socket"),true)
    }
}
