import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authenticated foreground guest transport. Action callers own authorization and replay prevention.
public protocol GuestActionTransport: AnyObject {
    func sendAction(_ frame: Data) async throws
    func close()
}

public final class GuestLiveSession: GuestActionTransport {
    public let frames: AsyncThrowingStream<Data, Error>
    private let socket: URLSessionWebSocketTask

    init(socket: URLSessionWebSocketTask, invite: GuestInvite, fingerprint: String) {
        self.socket = socket
        socket.maximumMessageSize = 1_048_576
        frames = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { continuation in
            let worker = Task {
                socket.resume()
                let deadline = Task {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    socket.cancel(with: .goingAway, reason: nil)
                }
                let heartbeat = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        socket.sendPing { error in
                            if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                        }
                    }
                }
                defer {
                    deadline.cancel()
                    heartbeat.cancel()
                    socket.cancel(with: .normalClosure, reason: nil)
                }
                do {
                    let hello = try GuestCrypto.hello(userKey: invite.userKey, fingerprint: fingerprint)
                    let data = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                    var authenticated = false
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        let bytes: Data
                        switch frame {
                        case .string(let value): bytes = Data(value.utf8)
                        case .data(let value): bytes = value
                        @unknown default: throw GuestAPI.Failure(status: 0, code: "invalid_response")
                        }
                        let event = try GuestEvent.decode(bytes)
                        if case .snapshot = event { authenticated = true; deadline.cancel() }
                        if !authenticated {
                            switch event {
                            case .snapshot, .unavailable: break
                            default: continue
                            }
                        }
                        switch continuation.yield(bytes) {
                        case .enqueued: break
                        case .terminated: return
                        case .dropped: throw GuestAPI.Failure(status: 0, code: "event_overflow")
                        @unknown default: throw GuestAPI.Failure(status: 0, code: "event_overflow")
                        }
                        if case .unavailable = event { break }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    public func requestAvatars(numberIDs: [Int]) async throws {
        for id in Set(numberIDs).filter({ $0 > 0 }).sorted().prefix(64) {
            let body = try JSONSerialization.data(withJSONObject: ["type": "avatar_request", "number_id": id])
            try await socket.send(.string(String(decoding: body, as: UTF8.self)))
        }
    }

    public func sendAction(_ frame: Data) async throws {
        try await socket.send(.string(ControlFrameValidation.guest(frame)))
    }

    public func close() { socket.cancel(with: .goingAway, reason: nil) }
    deinit { close() }
}
