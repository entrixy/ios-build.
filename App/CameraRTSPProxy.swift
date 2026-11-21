import Foundation
import Network
import EntrixyCore

/// The decoder only connects to a capability-protected loopback RTSP endpoint.
/// This bridge pins one camera origin, owns Basic/Digest/custom authorization,
/// rewrites SDP/control addresses and allows only TCP-interleaved camera reads.
@MainActor final class CameraRTSPProxy {
    private final class Peer {
        let local: NWConnection, remote: NWConnection
        var pending: [String: CameraRTSPMessage] = [:]
        var retried = Set<String>()
        var digest: CameraRTSPDigest?
        var nonceCount: UInt32 = 0
        var tasks: [Task<Void, Never>] = []
        init(_ local: NWConnection, _ remote: NWConnection) { self.local = local; self.remote = remote }
    }
    private let camera: CameraRequest
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.entrixy.camera.rtsp")
    private let capability = GuestCrypto.base64URL(GuestCrypto.randomBytes(count: 32))
    private var resources: [String: URL] = [:]
    private var peers: [UUID: Peer] = [:]
    private var origin: URL?
    private var active = false
    private var readiness: CheckedContinuation<URL, Error>?
    var failed: ((Error) -> Void)?

    init(camera: CameraRequest) throws {
        guard camera.url.scheme?.lowercased() == "rtsp", camera.url.host != nil,
              camera.headers.keys.allSatisfy({ !["cseq", "content-length", "transport", "session", "host", "connection"].contains($0.lowercased()) }) else { throw CameraStreamFailure.format }
        self.camera = camera
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.includePeerToPeer = false
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> URL {
        guard !active else { throw CameraStreamFailure.format }; active = true
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in self?.changed(state) } }
                listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
                listener.start(queue: queue)
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.stop() } })
    }
    func stop() {
        active = false; listener.cancel()
        let pending = readiness; readiness = nil; pending?.resume(throwing: CancellationError())
        for id in Array(peers.keys) { close(id) }; resources.removeAll()
    }
    private func changed(_ state: NWListener.State) {
        guard active else { return }
        switch state {
        case .ready:
            do {
                guard let port = listener.port, let base = URL(string: "rtsp://127.0.0.1:\(port.rawValue)") else { throw CameraStreamFailure.format }
                origin = base
                let address = try register(camera.url), pending = readiness; readiness = nil; pending?.resume(returning: address)
            } catch { let pending = readiness; readiness = nil; pending?.resume(throwing: error); stop() }
        case .failed(let error): let pending = readiness; readiness = nil; pending?.resume(throwing: error); stop()
        default: break
        }
    }
    private func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "rtsp" && url.host?.lowercased() == camera.url.host?.lowercased()
            && (url.port ?? 554) == (camera.url.port ?? 554) && url.user == nil && url.password == nil && url.fragment == nil
    }
    private func register(_ url: URL) throws -> URL {
        guard active, allows(url), let origin, resources.count < 128 else { throw CameraStreamFailure.format }
        if let known = resources.first(where: { $0.value == url }) { return origin.appendingPathComponent(known.key) }
        let token = capability + "/" + UUID().uuidString.lowercased()
        resources[token] = url; return origin.appendingPathComponent(token)
    }
    private func target(_ text: String) throws -> URL {
        if text == "*" { return camera.url }
        guard let url = URL(string: text), url.scheme == "rtsp", url.host == "127.0.0.1", url.port == origin?.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let target = resources[String(url.path.dropFirst())] else { throw CameraStreamFailure.format }
        return target
    }
    private func accept(_ connection: NWConnection) {
        guard active, peers.count < 4, let host = camera.url.host,
              let portValue = UInt16(exactly: camera.url.port ?? 554),
              let port = NWEndpoint.Port(rawValue: portValue) else { connection.cancel(); return }
        let remote = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let peer = Peer(connection, remote), id = UUID(); peers[id] = peer
        connection.start(queue: queue); remote.start(queue: queue)
        peer.tasks = [Task { [weak self] in guard let self else { return }; await self.pumpClient(id) },
                      Task { [weak self] in guard let self else { return }; await self.pumpCamera(id) }]
    }
    private func close(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.local.cancel(); peer.remote.cancel(); peer.tasks.forEach { $0.cancel() }
    }
    private func authorize(_ message: inout CameraRTSPMessage, peer: Peer) throws {
        for (name, value) in camera.headers { message.headers[name.lowercased()] = value }
        if let digest = peer.digest, let request = message.request, let basic = message.headers["authorization"] {
            guard peer.nonceCount < UInt32.max else { throw CameraStreamFailure.format }; peer.nonceCount += 1
            message.headers["authorization"] = try digest.authorization(basic: basic, method: request.method, uri: request.uri, count: peer.nonceCount, cnonce: GuestCrypto.hash(GuestCrypto.randomBytes(count: 16)))
        }
    }
    private func pumpClient(_ id: UUID) async {
        guard let peer = peers[id] else { return }; var parser = CameraRTSPFramer()
        defer { close(id) }
        do {
            while active, !Task.isCancelled {
                let data = try await CameraSocket.read(peer.local)
                for frame in try parser.append(data) {
                    switch frame {
                    case .packet(let bytes): try await CameraSocket.send(bytes, on: peer.remote)
                    case .message(var message):
                        guard let request = message.request, message.body.isEmpty, let cseq = message.headers["cseq"], peer.pending[cseq] == nil, peer.pending.count < 32 else { throw CameraStreamFailure.format }
                        let remote = try target(request.uri)
                        if request.method == "SETUP" {
                            let transport = message.headers["transport"]?.lowercased() ?? ""
                            guard transport.contains("rtp/avp/tcp"), transport.contains("interleaved="), !transport.contains("destination="), !transport.contains("multicast") else { throw CameraStreamFailure.format }
                        }
                        message.start = request.method + " " + remote.absoluteString + " RTSP/1.0"
                        // Authentication is generated here only. Reject decoder-
                        // supplied credentials and proxy/cookie side channels.
                        message.headers.removeValue(forKey: "authorization"); message.headers.removeValue(forKey: "proxy-authorization")
                        message.headers.removeValue(forKey: "cookie"); message.headers.removeValue(forKey: "referer")
                        peer.pending[cseq] = message
                        try authorize(&message, peer: peer)
                        try await CameraSocket.send(message.encoded, on: peer.remote)
                    }
                }
            }
        } catch { if active, !Task.isCancelled { failed?(error) } }
    }
    private func pumpCamera(_ id: UUID) async {
        guard let peer = peers[id] else { return }; var parser = CameraRTSPFramer()
        defer { close(id) }
        do {
            while active, !Task.isCancelled {
                let data = try await CameraSocket.read(peer.remote)
                for frame in try parser.append(data) {
                    switch frame {
                    case .packet(let bytes): try await CameraSocket.send(bytes, on: peer.local)
                    case .message(var message):
                        guard let status = message.status, let cseq = message.headers["cseq"], var pending = peer.pending[cseq], let request = pending.request,
                              let requestURL = URL(string: request.uri) else { throw CameraStreamFailure.format }
                        if status == 401 {
                            guard !peer.retried.contains(cseq), let challenge = message.headers["www-authenticate"] else { throw URLError(.userAuthenticationRequired) }
                            peer.digest = try CameraRTSPDigest(challenge: challenge); peer.retried.insert(cseq)
                            try authorize(&pending, peer: peer); try await CameraSocket.send(pending.encoded, on: peer.remote); continue
                        }
                        guard status < 300 else { throw CameraStreamFailure.http(status) }
                        peer.pending.removeValue(forKey: cseq); peer.retried.remove(cseq)
                        var base = requestURL
                        for header in ["content-base", "content-location"] {
                            if let value = message.headers[header] {
                                guard let address = URL(string: value, relativeTo: requestURL)?.absoluteURL else { throw CameraStreamFailure.format }
                                message.headers[header] = try register(address).absoluteString
                                if header == "content-base" { base = address }
                            }
                        }
                        if message.headers["content-type"]?.lowercased().hasPrefix("application/sdp") == true {
                            guard let sdp = String(data: message.body, encoding: .utf8) else { throw CameraStreamFailure.format }
                            var lines: [String] = []
                            let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                            for original in normalized.components(separatedBy: "\n") {
                                let line = original.trimmingCharacters(in: .whitespaces)
                                if line.hasPrefix("a=control:"), line != "a=control:*" {
                                    guard let uri = URL(string: String(line.dropFirst(10)), relativeTo: base)?.absoluteURL else { throw CameraStreamFailure.format }
                                    lines.append("a=control:" + (try register(uri)).absoluteString)
                                } else { lines.append(line) }
                            }
                            message.body = Data(lines.joined(separator: "\r\n").utf8)
                        }
                        if var info = message.headers["rtp-info"] {
                            let regex = try NSRegularExpression(pattern: #"url=([^;,\s]+)"#, options: .caseInsensitive)
                            for match in regex.matches(in: info, range: NSRange(info.startIndex..., in: info)).reversed() {
                                guard let range = Range(match.range(at: 1), in: info), let uri = URL(string: String(info[range]), relativeTo: base)?.absoluteURL else { throw CameraStreamFailure.format }
                                let local = try register(uri).absoluteString; info.replaceSubrange(range, with: local)
                            }
                            message.headers["rtp-info"] = info
                        }
                        for name in ["www-authenticate", "authentication-info", "set-cookie", "server", "location"] { message.headers.removeValue(forKey: name) }
                        try await CameraSocket.send(message.encoded, on: peer.local)
                    }
                }
            }
        } catch { if active, !Task.isCancelled { failed?(error) } }
    }
}

enum CameraSocket {
    static func read(_ connection: NWConnection) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: URLError(complete ? .networkConnectionLost : .badServerResponse)) }
            }
        }
    }
    static func send(_ data: Data, on connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
