import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol OwnerLiveTransport: GuestActionTransport {
    var frames: AsyncThrowingStream<Data, Error> { get }
}

/// Foreground owner socket. Reconnection never sends an actuation request.
public final class OwnerLiveSession: OwnerLiveTransport {
    public let frames: AsyncThrowingStream<Data, Error>
    private let socket: URLSessionWebSocketTask

    init(socket: URLSessionWebSocketTask, credentials: OwnerCredentials, fingerprint: String) {
        self.socket = socket
        socket.maximumMessageSize = 1_048_576
        frames = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            let worker = Task {
                socket.resume()
                let deadline = Task {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    socket.cancel(with: .goingAway, reason: nil)
                }
                let heartbeat = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        socket.sendPing { error in if error != nil { socket.cancel(with: .goingAway, reason: nil) } }
                    }
                }
                defer { deadline.cancel(); heartbeat.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
                do {
                    let hello: [String: String] = ["type": "host_hello", "device_id": credentials.deviceID,
                        "device_secret": credentials.deviceSecret, "device_fp": fingerprint, "lang": "ru"]
                    try await socket.send(.data(JSONSerialization.data(withJSONObject: hello, options: .sortedKeys)))
                    var authenticated = false
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        let bytes: Data
                        switch frame {
                        case .string(let text): bytes = Data(text.utf8)
                        case .data(let data): bytes = data
                        @unknown default: throw GuestCrypto.Failure.invalidEnvelope
                        }
                        guard bytes.count <= 1_048_576, let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                              let type = json["type"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
                        if type == "host_ok" { authenticated = true; deadline.cancel() }
                        if !authenticated && !["error", "evicted"].contains(type) { continue }
                        switch continuation.yield(bytes) {
                        case .enqueued: break
                        case .terminated: return
                        case .dropped: throw GuestCrypto.Failure.invalidEnvelope
                        @unknown default: throw GuestCrypto.Failure.invalidEnvelope
                        }
                        if type == "evicted" || (!authenticated && type == "error") { break }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        }
    }
    public func sendAction(_ frame: Data) async throws {
        try await socket.send(.string(ControlFrameValidation.owner(frame)))
    }
    public func close() { socket.cancel(with: .goingAway, reason: nil) }
    deinit { close() }
}
