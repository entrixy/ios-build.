import SwiftUI
import VLCKit

/// Isolated decoder: its only input is a loopback camera capability. The network
/// bridges own remote addresses, redirects, credentials and segment validation.
@MainActor final class CameraSoftwareVideo: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let view = UIView()
    private let player = VLCMediaPlayer(options: ["--no-audio", "--rtsp-tcp", "--no-video-title-show", "--no-snapshot-preview", "--no-sub-autodetect-file", "--no-lua"])
    private var active = true
    private var lastSize = CGSize.zero
    var hasDecodedVideo: Bool { player.hasVideoOut && player.videoSize.width > 0 && player.videoSize.height > 0 }
    var changed: ((Bool) -> Void)?
    var resized: ((CGSize) -> Void)?
    init(url: URL) throws {
        guard ["http", "rtsp"].contains(url.scheme), url.host == "127.0.0.1", url.port != nil, url.user == nil, url.password == nil else { throw CameraStreamFailure.format }
        super.init()
        view.backgroundColor = .black
        player.delegate = self; player.drawable = view
        guard let media = VLCMedia(url: url) else { throw CameraStreamFailure.format }
        media.addOption(":network-caching=300")
        media.addOption(":rtsp-tcp")
        player.media = media; player.play()
    }
    func stop() {
        active = false; changed = nil; resized = nil; player.delegate = nil; player.stop(); player.drawable = nil
    }
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            if newState == .playing { self.publishSize(); self.changed?(true) }
            else if newState == .error || newState == .stopped { self.changed?(false) }
        }
    }
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in guard let self, self.active else { return }; self.publishSize() }
    }
    private func publishSize() {
        let size = player.videoSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size; resized?(size)
    }
}

struct CameraSoftwareSurface: UIViewRepresentable {
    let video: CameraSoftwareVideo
    func makeUIView(context: Context) -> UIView { video.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
