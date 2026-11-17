import Foundation
import Network
import EntrixyCore

/// Opaque CONNECT tunnel. URLSession retains TLS, certificate validation, HTTP
/// signing and WebSocket semantics; this layer selects only the TCP interface.
/// Not installed in the live app until policy persistence/guards are connected.
@MainActor final class ServerPrivacyProxy {
    struct Address: Sendable {
        let port: UInt16
        let username: String
        let password: String
        var authorization: String { "Basic " + Data((username+":"+password).utf8).base64EncodedString() }
        @available(iOS 17.0, *)
        func configure(_ configuration: URLSessionConfiguration) {
            var proxy = ProxyConfiguration(httpCONNECTProxy:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!),tlsOptions:nil)
            proxy.allowFailover = false
            proxy.applyCredential(username:username,password:password)
            configuration.proxyConfigurations = [proxy]
        }
    }
    typealias Decision = @MainActor (ServerProxyConnect) async -> ServerNetworkRoute
    typealias Connect = @MainActor (String,UInt16,ServerNetworkRoute) -> NWConnection
    private final class Tunnel {
        let id = UUID()
        let local: NWConnection
        var remote: NWConnection?
        var route: ServerNetworkRoute?
        var established = false
        var header = Data()
        var timeout: Task<Void,Never>?
        var decision: Task<Void,Never>?
        var idle: Task<Void,Never>?
        var ended = 0
        init(_ connection: NWConnection) { local = connection }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label:"com.entrixy.server.privacy")
    private let username = "Entrixy"
    private let password = GuestCrypto.base64URL(GuestCrypto.randomBytes(count:32))
    private let decide: Decision
    private let connect: Connect
    private var active = false
    private var address: Address?
    private var readiness: CheckedContinuation<Address,Error>?
    private var startupTimeout: Task<Void,Never>?
    private var tunnels: [UUID:Tunnel] = [:]
    init(decide: @escaping Decision,connect: Connect? = nil) throws {
        self.decide = decide
        self.connect = connect ?? { host,port,route in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            if route == .cellular {
                parameters.requiredInterfaceType = .cellular
                parameters.prohibitedInterfaceTypes = [.wifi,.wiredEthernet]
            }
            return NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:port)!,using:parameters)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        parameters.includePeerToPeer = false
        listener = try NWListener(using:parameters,on:.any)
    }
    func start() async throws -> Address {
        guard !active else { throw URLError(.cannotConnectToHost) }; active = true
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in self?.changed(state) } }
                listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
                listener.start(queue:queue)
                startupTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds:15_000_000_000) } catch { return }
                    if self?.readiness != nil { self?.stop() }
                }
            }
        },onCancel:{ Task { @MainActor [weak self] in self?.stop() } })
    }
    func stop() {
        active = false; listener.cancel(); startupTimeout?.cancel(); startupTimeout = nil
        let pending = readiness; readiness = nil; pending?.resume(throwing:CancellationError())
        for tunnel in Array(tunnels.values) { close(tunnel) }
        address = nil
    }
    /// Tightening a rule also ends already-open default-interface tunnels.
    /// Loosening rules lets safe cellular connections finish normally.
    func restrict(to route: ServerNetworkRoute) {
        guard route != .system else { return }
        for tunnel in Array(tunnels.values) where route == .blocked || tunnel.route != .cellular { close(tunnel) }
    }
    private func changed(_ state: NWListener.State) {
        guard active else { return }
        switch state {
        case .ready:
            guard let port = listener.port else { stop(); return }
            let value = Address(port:port.rawValue,username:username,password:password)
            address = value; startupTimeout?.cancel(); startupTimeout = nil
            let pending = readiness; readiness = nil; pending?.resume(returning:value)
        case .failed(let error):
            let pending = readiness; readiness = nil; pending?.resume(throwing:error); stop()
        default: break
        }
    }
    private func accept(_ connection: NWConnection) {
        guard active, address != nil, Self.isLoopback(connection.endpoint), tunnels.count < 128 else { connection.cancel(); return }
        let tunnel = Tunnel(connection); tunnels[tunnel.id] = tunnel
        connection.stateUpdateHandler = { [weak self,weak tunnel] state in
            Task { @MainActor in
                guard let self,let tunnel,self.contains(tunnel) else { return }
                if case .failed = state { self.close(tunnel) }
            }
        }
        connection.start(queue:queue)
        tunnel.timeout = Task { [weak self,weak tunnel] in
            do { try await Task.sleep(nanoseconds:15_000_000_000) } catch { return }
            if let self,let tunnel { self.close(tunnel) }
        }
        readHeader(tunnel)
    }
    private func contains(_ tunnel: Tunnel) -> Bool { active && tunnels[tunnel.id] === tunnel }
    private func readHeader(_ tunnel: Tunnel) {
        tunnel.local.receive(minimumIncompleteLength:1,maximumLength:32768) { [weak self,weak tunnel] data,_,complete,error in
            Task { @MainActor in
                guard let self,let tunnel,self.contains(tunnel) else { return }
                if let data { tunnel.header.append(data) }
                do {
                    guard let address = self.address else { throw CancellationError() }
                    let request = try ServerProxyConnect(tunnel.header,authorization:address.authorization)
                    tunnel.header.removeAll()
                    tunnel.decision = Task { [weak self,weak tunnel] in
                        guard let self,let tunnel,self.contains(tunnel) else { return }
                        let route = await self.decide(request)
                        guard self.contains(tunnel) else { return }
                        guard route != .blocked else { self.reject(tunnel,status:503); return }
                        self.open(tunnel,request:request,route:route)
                    }
                } catch ServerProxyConnect.Failure.incomplete {
                    if error != nil || complete { self.close(tunnel) } else { self.readHeader(tunnel) }
                } catch ServerProxyConnect.Failure.unauthorized { self.reject(tunnel,status:407) }
                catch { self.reject(tunnel,status:400) }
            }
        }
    }
    private func open(_ tunnel: Tunnel,request: ServerProxyConnect,route: ServerNetworkRoute) {
        let remote = connect(request.host,request.port,route); tunnel.remote = remote; tunnel.route = route
        remote.stateUpdateHandler = { [weak self,weak tunnel] state in
            Task { @MainActor in
                guard let self,let tunnel,self.contains(tunnel) else { return }
                switch state {
                case .ready:
                    guard !tunnel.established else { return }; tunnel.established = true
                    tunnel.timeout?.cancel(); tunnel.timeout = nil; self.touch(tunnel)
                    tunnel.local.send(content:Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),completion:.contentProcessed { [weak self,weak tunnel] error in
                        Task { @MainActor in
                            guard let self,let tunnel,self.contains(tunnel),let remote = tunnel.remote else { return }
                            if error != nil { self.close(tunnel); return }
                            if request.remainder.isEmpty { self.forward(tunnel,from:tunnel.local,to:remote) }
                            else {
                                remote.send(content:request.remainder,completion:.contentProcessed { [weak self,weak tunnel] error in
                                    Task { @MainActor in
                                        guard let self,let tunnel,self.contains(tunnel),let remote = tunnel.remote else { return }
                                        if error != nil { self.close(tunnel) } else { self.forward(tunnel,from:tunnel.local,to:remote) }
                                    }
                                })
                            }
                            self.forward(tunnel,from:remote,to:tunnel.local)
                        }
                    })
                case .failed:
                    if tunnel.established { self.close(tunnel) } else { self.reject(tunnel,status:502) }
                default: break
                }
            }
        }
        remote.start(queue:queue)
    }
    private func forward(_ tunnel: Tunnel,from source: NWConnection,to destination: NWConnection) {
        source.receive(minimumIncompleteLength:1,maximumLength:32768) { [weak self,weak tunnel] data,_,complete,error in
            Task { @MainActor in
                guard let self,let tunnel,self.contains(tunnel) else { return }
                if error != nil { self.close(tunnel); return }
                self.touch(tunnel)
                if let data,!data.isEmpty {
                    destination.send(content:data,completion:.contentProcessed { [weak self,weak tunnel] error in
                        Task { @MainActor in
                            guard let self,let tunnel,self.contains(tunnel) else { return }
                            if error != nil { self.close(tunnel) }
                            else if complete { self.end(tunnel,to:destination) }
                            else { self.forward(tunnel,from:source,to:destination) }
                        }
                    })
                } else if complete { self.end(tunnel,to:destination) }
                else { self.forward(tunnel,from:source,to:destination) }
            }
        }
    }
    private func end(_ tunnel: Tunnel,to destination: NWConnection) {
        destination.send(content:nil,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed { [weak self,weak tunnel] _ in
            Task { @MainActor in
                guard let self,let tunnel,self.contains(tunnel) else { return }
                tunnel.ended += 1; if tunnel.ended >= 2 { self.close(tunnel) }
            }
        })
    }
    private func touch(_ tunnel: Tunnel) {
        tunnel.idle?.cancel()
        tunnel.idle = Task { [weak self,weak tunnel] in
            do { try await Task.sleep(nanoseconds:300_000_000_000) } catch { return }
            if let self,let tunnel { self.close(tunnel) }
        }
    }
    private func reject(_ tunnel: Tunnel,status: Int) {
        guard contains(tunnel) else { return }
        let challenge = status == 407 ? "Proxy-Authenticate: Basic realm=\"Entrixy\"\r\n" : ""
        let message = "HTTP/1.1 \(status) Connection Rejected\r\n\(challenge)Content-Length: 0\r\nConnection: close\r\n\r\n"
        tunnel.local.send(content:Data(message.utf8),completion:.contentProcessed { [weak self,weak tunnel] _ in
            Task { @MainActor in if let self,let tunnel { self.close(tunnel) } }
        })
    }
    private func close(_ tunnel: Tunnel) {
        guard tunnels.removeValue(forKey:tunnel.id) != nil else { return }
        tunnel.timeout?.cancel(); tunnel.decision?.cancel(); tunnel.idle?.cancel()
        tunnel.local.cancel(); tunnel.remote?.cancel()
    }
    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host,_) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            return bytes == [UInt8](repeating:0,count:15)+[1]
                || (bytes.count == 16 && Array(bytes.prefix(12)) == [UInt8](repeating:0,count:10)+[255,255] && bytes[12] == 127)
        case .name(let name,_): return name == "127.0.0.1" || name == "::1"
        @unknown default: return false
        }
    }
}
