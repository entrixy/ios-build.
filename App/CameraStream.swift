import Foundation
import SwiftUI
import AVKit
import ImageIO
import EntrixyCore

struct ObjectCameraContext: Equatable {
    let configuration: ObjectCameraConfiguration
    let guestUserKey: String?
    let localKeyID: String
}

final class CameraHTTPBoundary: NSObject, URLSessionTaskDelegate {
    let camera: CameraRequest
    init(_ camera: CameraRequest) { self.camera = camera }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, camera.allowsRedirect(to:url) else { completionHandler(nil); return }
        var next = request
        for (name,value) in camera.headers { next.setValue(value,forHTTPHeaderField:name) }
        completionHandler(next)
    }
}

struct CameraHTTPFrames {
    let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
    func load(_ camera: CameraRequest, onFrame: @escaping @MainActor (Data) throws -> Void) async throws {
        guard ["https","http"].contains(camera.url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let settings = configuration.copy() as! URLSessionConfiguration
        settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false; settings.urlCache = nil
        settings.timeoutIntervalForRequest = 15; settings.timeoutIntervalForResource = 3600
        let session = URLSession(configuration:settings,delegate:CameraHTTPBoundary(camera),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url:camera.url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
        for (name,value) in camera.headers { request.setValue(value,forHTTPHeaderField:name) }
        if request.value(forHTTPHeaderField:"User-Agent") == nil { request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",forHTTPHeaderField:"User-Agent") }
        let (bytes,response) = try await session.bytes(for:request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CameraStreamFailure.http(code)
        }
        let multipart = camera.media == .multipartJPEG || http.mimeType?.lowercased().hasPrefix("multipart/") == true
        if multipart {
            var parser = CameraJPEGFrames()
            var delivered = false
            for try await byte in bytes {
                try Task.checkCancellation()
                if let frame = try parser.receive(byte) { delivered = true; try await onFrame(frame) }
            }
            guard delivered else { throw CameraStreamFailure.format }
        } else {
            var image = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard image.count < 8_388_608 else { throw CameraStreamFailure.format }
                image.append(byte)
            }
            try await onFrame(image)
        }
    }
}

enum CameraStreamFailure: Error { case http(Int), format }

@MainActor final class CameraStreamModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var message: String?
    @Published private(set) var loading = true
    private var worker: Task<Void,Never>?
    private var timeout: Task<Void,Never>?
    private var observation: NSKeyValueObservation?
    private var generation = UUID()
    private let transport: CameraHTTPFrames
    private var videoProxy: CameraVideoProxy?
    init(transport: CameraHTTPFrames = CameraHTTPFrames()) { self.transport = transport }
    func stop() {
        generation = UUID(); worker?.cancel(); worker = nil; timeout?.cancel(); timeout = nil
        observation = nil; player?.pause(); player = nil
        videoProxy?.stop(); videoProxy = nil
    }
    func start(_ context: ObjectCameraContext) {
        stop(); loading = true; message = nil; image = nil
        let current = generation
        armTimeout(current)
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try CameraRequest(configuration:context.configuration,guestUserKey:context.guestUserKey,localKeyID:context.localKeyID)
                switch request.media {
                case .otherVideo: throw CameraStreamFailure.format
                case .nativeVideo:
                    var address = request.url
                    if request.authenticated {
                        let bridge = try CameraVideoProxy(camera:request,configuration:self.transport.configuration)
                        self.videoProxy = bridge
                        bridge.failed = { [weak self] error in guard let self, self.generation == current else { return }; self.fail(Self.error(error)) }
                        address = try await bridge.start()
                    }
                    guard self.generation == current, !Task.isCancelled else { return }
                    let item = AVPlayerItem(url:address)
                    self.observation = item.observe(\.status,options:[.initial,.new]) { [weak self] item,_ in
                        Task { @MainActor in
                            guard let self, self.generation == current else { return }
                            if item.status == .readyToPlay { self.loading = false; self.timeout?.cancel() }
                            else if item.status == .failed, self.message == nil { self.fail(Self.error(item.error)) }
                        }
                    }
                    self.player = AVPlayer(playerItem:item); self.player?.isMuted = true; self.player?.play()
                case .image, .multipartJPEG:
                    repeat {
                        self.loading = true
                        self.armTimeout(current)
                        let fresh = try CameraRequest(configuration:context.configuration,guestUserKey:context.guestUserKey,localKeyID:context.localKeyID)
                        try await self.transport.load(fresh) { [weak self] data in
                            guard let self, self.generation == current else { throw CancellationError() }
                            guard let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                                  let frame = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2048] as CFDictionary) else { throw CameraStreamFailure.format }
                            self.image = UIImage(cgImage:frame); self.loading = false; self.message = nil; self.timeout?.cancel()
                        }
                        guard self.generation == current else { return }
                        guard self.image != nil else { throw CameraStreamFailure.format }
                        if fresh.media == .multipartJPEG || context.configuration.intervalSec == 0 { break }
                        try await Task.sleep(nanoseconds:UInt64(context.configuration.intervalSec)*1_000_000_000)
                    } while !Task.isCancelled && self.generation == current
                }
            } catch is CancellationError { }
            catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.fail(Self.error(error))
            }
        }
    }
    private func armTimeout(_ current: UUID) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:15_000_000_000) } catch { return }
            guard let self, self.generation == current, self.loading else { return }
            self.fail(ProductText.string("stream_timeout")); self.worker?.cancel(); self.player?.pause()
        }
    }
    private func fail(_ text: String) { loading = false; message = text; timeout?.cancel(); videoProxy?.stop(); videoProxy = nil; player?.pause() }
    private static func error(_ error: Error?) -> String {
        guard let error else { return ProductText.string("stream_err_unknown") }
        if case CameraStreamFailure.http(let code) = error {
            return ProductText.string(code == 403 ? "stream_err_403" : code == 404 ? "stream_err_404" : "stream_err_connect")
        }
        if error is CameraStreamFailure || error is CameraJPEGFrames.Failure { return ProductText.string("stream_err_format") }
        switch (error as? URLError)?.code {
        case .timedOut: return ProductText.string("stream_err_timeout")
        case .cannotFindHost, .dnsLookupFailed: return ProductText.string("stream_err_dns")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: return ProductText.string("stream_err_ssl")
        case .unsupportedURL, .cannotDecodeContentData, .cannotDecodeRawData: return ProductText.string("stream_err_format")
        default: return ProductText.string("stream_err_connect")
        }
    }
}

struct ObjectCameraStream: View {
    let context: ObjectCameraContext
    @StateObject private var model = CameraStreamModel()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack {
            Color(uiColor:.secondarySystemGroupedBackground)
            if let player = model.player { VideoPlayer(player:player).allowsHitTesting(false) }
            else if let image = model.image { Image(uiImage:image).resizable().scaledToFit() }
            if model.loading { ProgressView().accessibilityLabel("Загрузка") }
            if let message = model.message {
                VStack(spacing:8) {
                    Text(ProductText.string("stream_unavailable")).font(.subheadline.weight(.semibold))
                    Text(ProductText.systemMessage(message)).font(.footnote).multilineTextAlignment(.center)
                }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(uiColor:.secondarySystemGroupedBackground))
            }
        }
        .aspectRatio(aspect,contentMode:.fit).frame(minHeight:120,maxHeight:320)
        .clipShape(RoundedRectangle(cornerRadius:12)).privacySensitive()
        .task(id:context) { if phase == .active { model.start(context) } }
        .onChange(of:phase) { value in if value == .active { model.start(context) } else { model.stop() } }
        .onDisappear { model.stop() }
    }
    private var aspect: CGFloat { model.image.map { $0.size.width/max(1,$0.size.height) } ?? 16/9 }
}

extension AppModel {
    func cameraContext(_ target: ObjectReference) -> ObjectCameraContext? {
        guard canManageGuestAccess, objectIsVisible(target) else { return nil }
        switch target {
        case .owned(let server,let id):
            guard let owner = owners.first(where:{ $0.server == server && $0.ownershipLost != true }), let object = owner.objects?.first(where:{ $0.id == id }),
                  let camera = object.localConfiguration?.camera, camera.enabled, !camera.url.isEmpty else { return nil }
            return ObjectCameraContext(configuration:camera,guestUserKey:nil,localKeyID:"0")
        case .received(let guestID,let objectID):
            guard let guest = guests.first(where:{ $0.id == guestID }), !guest.paused,
                  guest.objects.contains(where:{ $0.id == objectID }), let camera = guest.cameras?[objectID], camera.enabled, !camera.url.isEmpty else { return nil }
            let localID = String(UInt32(GuestCrypto.hash(Data(guest.id.utf8)).prefix(8),radix:16) ?? 0)
            return ObjectCameraContext(configuration:camera,guestUserKey:guest.invite.userKey,localKeyID:localID)
        }
    }
}
