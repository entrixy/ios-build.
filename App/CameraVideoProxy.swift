import Foundation
import Network
import EntrixyCore

/// A per-visible-camera loopback bridge lets AVFoundation use authenticated
/// HTTP/HLS without private AVURLAsset option keys. No remote address, credential
/// or query token is exposed in the player's URL. Only registered read resources
/// on the camera origin are fetched; the bridge closes with its camera view.
@MainActor final class CameraVideoProxy {
    private let camera: CameraRequest
    private let session: URLSession
    private let listener: NWListener
    private let queue = DispatchQueue(label:"com.entrixy.camera.video")
    private let capability = GuestCrypto.base64URL(GuestCrypto.randomBytes(count:32))
    private let resourceKey = GuestCrypto.randomBytes(count:32)
    private var names: [URL:String] = [:]
    private var order: [URL] = []
    private var connections: [UUID:NWConnection] = [:]
    private var tasks: [UUID:Task<Void,Never>] = [:]
    private var readiness: CheckedContinuation<URL,Error>?
    private var active = false
    private var origin: URL?
    var failed: ((Error) -> Void)?

    init(camera: CameraRequest,configuration: URLSessionConfiguration = .ephemeral) throws {
        guard [.nativeVideo, .otherVideo].contains(camera.media), ["https","http"].contains(camera.url.scheme?.lowercased() ?? "") else { throw CameraStreamFailure.format }
        self.camera = camera
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:NWEndpoint.Host("127.0.0.1"),port:.any)
        parameters.includePeerToPeer = false
        listener = try NWListener(using:parameters,on:.any)
        let settings = configuration.copy() as! URLSessionConfiguration
        settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false; settings.urlCache = nil
        settings.timeoutIntervalForRequest = 15; settings.timeoutIntervalForResource = 3600
        session = URLSession(configuration:settings,delegate:CameraHTTPBoundary(camera),delegateQueue:nil)
    }
    func start() async throws -> URL {
        guard !active else { throw CameraStreamFailure.format }; active = true
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in self?.changed(state) } }
                listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
                listener.start(queue:queue)
            }
        },onCancel:{ Task { @MainActor [weak self] in self?.stop() } })
    }
    func stop() {
        active = false; listener.cancel(); session.invalidateAndCancel()
        let pending = readiness; readiness = nil; pending?.resume(throwing:CancellationError())
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        names.removeAll(); order.removeAll()
    }
    private func changed(_ state: NWListener.State) {
        guard active else { return }
        switch state {
        case .ready:
            guard let port = listener.port, let address = URL(string:"http://127.0.0.1:\(port.rawValue)") else { stop(); return }
            origin = address
            do { let url = try register(camera.url); let pending = readiness; readiness = nil; pending?.resume(returning:url) }
            catch { let pending = readiness; readiness = nil; pending?.resume(throwing:error); stop() }
        case .failed(let error):
            let pending = readiness; readiness = nil; pending?.resume(throwing:error); stop()
        default: break
        }
    }
    private func register(_ url: URL) throws -> URL {
        guard active, camera.allowsRedirect(to:url), let origin else { throw CameraStreamFailure.format }
        if let name = names[url] { return origin.appendingPathComponent(name) }
        let suffix = url.pathExtension.lowercased()
        let ext = ["m3u8","mpd","webm","mkv","mp4","mov","m4v","ts","m4s","aac","vtt","key"].contains(suffix) ? "." + suffix : ""
        guard url.absoluteString.utf8.count <= 8192 else { throw CameraStreamFailure.format }
        let sealed = try GuestCrypto.encrypt(key:resourceKey,plaintext:Data(url.absoluteString.utf8))
        let name = capability + "/" + GuestCrypto.base64URL(Data(sealed.utf8)) + ext
        names[url] = name; order.append(url)
        // This cache only stabilizes player URLs; evicting an entry does not
        // invalidate an already issued authenticated resource capability.
        while order.count > 2048 { names.removeValue(forKey:order.removeFirst()) }
        return origin.appendingPathComponent(name)
    }
    private func resource(_ path: String) throws -> URL {
        let dashPrefix = "/" + capability + "/dash/"
        if path.hasPrefix(dashPrefix) {
            let pieces = path.dropFirst(dashPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard let token = pieces.first, !token.isEmpty,
                  let envelope = String(data: try GuestCrypto.decodeBase64URL(String(token)), encoding: .utf8) else { throw CameraStreamFailure.format }
            let clear = try GuestCrypto.decrypt(key: resourceKey, envelope: envelope)
            guard clear.count <= 16384 else { throw CameraStreamFailure.format }
            let template = try JSONDecoder().decode(CameraDASHTemplate.self, from: clear)
            let address = try template.expanded(pieces.dropFirst().map(String.init))
            guard camera.allowsRedirect(to: address) else { throw CameraStreamFailure.format }; return address
        }
        let prefix = "/" + capability + "/"
        guard path.hasPrefix(prefix) else { throw CameraStreamFailure.format }
        guard let token = path.dropFirst(prefix.count).split(separator:".",maxSplits:1).first, !token.isEmpty else { throw CameraStreamFailure.format }
        guard let envelope = String(data:try GuestCrypto.decodeBase64URL(String(token)),encoding:.utf8) else { throw CameraStreamFailure.format }
        let clear = try GuestCrypto.decrypt(key:resourceKey,envelope:envelope)
        guard clear.count <= 8192, let text = String(data:clear,encoding:.utf8), let url = URL(string:text), camera.allowsRedirect(to:url) else { throw CameraStreamFailure.format }
        return url
    }
    private func registerDASH(_ value: String, base: URL) throws -> String {
        let template = try CameraDASHTemplate(value, base: base)
        let sample = try template.expanded(template.fields.map { _ in "0" })
        guard camera.allowsRedirect(to: sample), let origin else { throw CameraStreamFailure.format }
        if template.fields.isEmpty { return try register(sample).absoluteString }
        let clear = try JSONEncoder().encode(template)
        let envelope = try GuestCrypto.encrypt(key: resourceKey, plaintext: clear)
        let token = GuestCrypto.base64URL(Data(envelope.utf8))
        return origin.absoluteString + "/" + capability + "/dash/" + token + "/" + template.fields.joined(separator: "/")
    }
    private func accept(_ connection: NWConnection) {
        guard active, Self.isLoopback(connection.endpoint), connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue:queue)
        tasks[id] = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            defer { self.connections.removeValue(forKey:id); self.tasks.removeValue(forKey:id); connection.cancel() }
            await self.serve(connection)
        }
    }
    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host,_) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            return bytes == [UInt8](repeating:0,count:15) + [1]
                || (bytes.count == 16 && Array(bytes.prefix(12)) == [UInt8](repeating:0,count:10) + [255,255] && bytes[12] == 127)
        case .name(let name,_): return name == "127.0.0.1" || name == "::1"
        @unknown default: return false
        }
    }
    private func serve(_ connection: NWConnection) async {
        var sentHeaders = false
        var legitimate = false
        let headerTimeout = Task { try? await Task.sleep(nanoseconds:5_000_000_000); if !Task.isCancelled { connection.cancel() } }
        defer { headerTimeout.cancel() }
        do {
            let header = try await Self.header(connection); headerTimeout.cancel()
            let local = try CameraVideoHTTPRequest(header)
            guard let origin, let port = origin.port, local.host == "127.0.0.1:\(port)", local.path.hasPrefix("/" + capability + "/"),
                  let remote = try? resource(local.path) else { try await Self.failure(404,on:connection); return }
            legitimate = true
            let playlistURL = ["m3u8", "mpd"].contains(remote.pathExtension.lowercased())
            var request = URLRequest(url:remote,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
            request.httpMethod = playlistURL ? "GET" : local.method
            for (name,value) in camera.headers { request.setValue(value,forHTTPHeaderField:name) }
            request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
            if request.value(forHTTPHeaderField:"User-Agent") == nil { request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",forHTTPHeaderField:"User-Agent") }
            if !playlistURL, let range = local.range { request.setValue(range,forHTTPHeaderField:"Range") }
            let (bytes,response) = try await session.bytes(for:request)
            guard let http = response as? HTTPURLResponse, let finalURL = http.url, camera.allowsRedirect(to:finalURL) else { throw CameraStreamFailure.format }
            guard (200..<300).contains(http.statusCode) else { throw CameraStreamFailure.http(http.statusCode) }
            let mime = http.mimeType?.lowercased() ?? "application/octet-stream"
            guard mime.range(of:#"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#,options:.regularExpression) != nil else { throw CameraStreamFailure.format }
            let dash = remote.pathExtension.lowercased() == "mpd" || mime == "application/dash+xml"
            let playlist = playlistURL || mime.contains("mpegurl") || dash
            if playlist {
                var data = Data()
                for try await byte in bytes { try Task.checkCancellation(); guard data.count < 1_048_576 else { throw CameraStreamFailure.format }; data.append(byte) }
                let rewritten = try dash ? CameraDASHManifest.rewriting(data, base: finalURL, resource: { try self.registerDASH($0, base: $1) })
                    : CameraHLSPlaylist.rewriting(data,base:finalURL,resource:{ try self.register($0) })
                try await Self.send(Self.response(200,headers:["Content-Type":dash ? "application/dash+xml" : "application/vnd.apple.mpegurl","Content-Length":String(rewritten.count)]),on:connection); sentHeaders = true
                if local.method != "HEAD" { try await Self.send(rewritten,on:connection) }
            } else {
                var headers: [String:String] = ["Content-Type":mime]
                let compressed = http.value(forHTTPHeaderField:"Content-Encoding").map { $0.lowercased() != "identity" } ?? false
                if !compressed, let length = http.value(forHTTPHeaderField:"Content-Length"), length.range(of:#"^[0-9]{1,19}$"#,options:.regularExpression) != nil, Int64(length) != nil { headers["Content-Length"] = length }
                if let range = http.value(forHTTPHeaderField:"Content-Range"), range.range(of:#"^bytes [0-9]{1,19}-[0-9]{1,19}/(?:[0-9]{1,19}|\*)$"#,options:.regularExpression) != nil { headers["Content-Range"] = range }
                guard http.statusCode != 206 || (!compressed && headers["Content-Range"] != nil) else { throw CameraStreamFailure.format }
                if let range = http.value(forHTTPHeaderField:"Accept-Ranges"), ["bytes","none"].contains(range) { headers["Accept-Ranges"] = range }
                let chunked = headers["Content-Length"] == nil && local.method != "HEAD"
                if chunked { headers["Transfer-Encoding"] = "chunked" }
                try await Self.send(Self.response(http.statusCode,headers:headers),on:connection); sentHeaders = true
                if local.method == "HEAD" { try await Self.finish(connection); return }
                var buffer = Data()
                for try await byte in bytes {
                    try Task.checkCancellation(); guard active else { throw CancellationError() }; buffer.append(byte)
                    if buffer.count == 16384 { try await Self.sendBody(buffer,chunked:chunked,on:connection); buffer.removeAll(keepingCapacity:true) }
                }
                if !buffer.isEmpty { try await Self.sendBody(buffer,chunked:chunked,on:connection) }
                if chunked { try await Self.send(Data("0\r\n\r\n".utf8),on:connection) }
            }
            try await Self.finish(connection)
        } catch {
            if !sentHeaders { try? await Self.failure(502,on:connection) }
            // Players close an HTTP read when seeking or probing a container.
            // That loopback connection ending does not invalidate the camera
            // or the next authenticated request. Remote URLSession errors still
            // fail the stream, as do invalid manifests and authorization errors.
            let readerClosed: Bool
            if let networkError = error as? NWError, case let .posix(code) = networkError {
                readerClosed = [.EPIPE, .ECONNRESET, .ECANCELED, .ENOTCONN].contains(code)
            } else { readerClosed = false }
            if active, legitimate, !readerClosed, !(error is CancellationError), !Task.isCancelled {
                let reason: Error = error is GuestCrypto.Failure ? CameraStreamFailure.format : error
                failed?(reason)
            }
        }
    }
    private static func header(_ connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.range(of:Data("\r\n\r\n".utf8)) == nil {
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength:1,maximumLength:4096) { bytes,_,complete,error in
                    if let error { continuation.resume(throwing:error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning:bytes) }
                    else { continuation.resume(throwing:URLError(complete ? .networkConnectionLost : .badServerResponse)) }
                }
            }
            guard result.count + part.count <= 32768 else { throw CameraStreamFailure.format }; result.append(part)
        }
        return result
    }
    private static func send(_ bytes: Data,on connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            connection.send(content:bytes,completion:.contentProcessed { error in if let error { continuation.resume(throwing:error) } else { continuation.resume() } })
        }
    }
    private static func sendBody(_ bytes: Data,chunked: Bool,on connection: NWConnection) async throws {
        if chunked { try await send(Data((String(bytes.count,radix:16) + "\r\n").utf8) + bytes + Data("\r\n".utf8),on:connection) }
        else { try await send(bytes,on:connection) }
    }
    private static func response(_ status: Int,headers: [String:String]) -> Data {
        var text = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for name in headers.keys.sorted() { text += name + ": " + headers[name]! + "\r\n" }
        return Data((text + "\r\n").utf8)
    }
    private static func finish(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            connection.send(content:nil,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed { error in if let error { continuation.resume(throwing:error) } else { continuation.resume() } })
        }
    }
    private static func failure(_ status: Int,on connection: NWConnection) async throws {
        try await send(response(status,headers:["Content-Length":"0"]),on:connection); try await finish(connection)
    }
}
