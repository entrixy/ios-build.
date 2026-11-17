import Foundation
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import EntrixyCore

// Android SettingsScreen/SoundPlayer: same nine events, order and original files.
enum AppSoundEvent: String, Codable, CaseIterable, Identifiable {
    case tap, confirm, incall, geo, biometric, message, success, error, widget_fire
    var id: String { rawValue }
    var file: String { self == .tap ? "chpok" : self == .geo ? "geo_countdown" : rawValue }
    var title: String { ProductText.string("settings_sound_event_"+rawValue) }
}
private struct AppSoundPreferences: Codable {
    var volume: Float = 0.1
    var muted = Set<AppSoundEvent>()
    var custom = Set<AppSoundEvent>()
}

@MainActor final class AppSoundCenter: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    static let shared = AppSoundCenter()
    @Published private(set) var volume: Float = 0.1
    @Published private(set) var muted = Set<AppSoundEvent>()
    @Published private(set) var custom = Set<AppSoundEvent>()
    private let defaults: UserDefaults
    private let directory: URL
    private let notificationDirectory: URL
    private let key = "entrixy.event-sounds.v1"
    private var players: [AVAudioPlayer] = []
    private var bundled: [AppSoundEvent:Data] = [:]
    init(defaults: UserDefaults = .standard, directory: URL? = nil, notificationDirectory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EventSounds",isDirectory:true)
        self.notificationDirectory = notificationDirectory ?? FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask)[0].appendingPathComponent("Sounds",isDirectory:true)
        super.init()
        if let bytes = defaults.data(forKey:key), let preferences = try? JSONDecoder().decode(AppSoundPreferences.self,from:bytes), preferences.volume.isFinite {
            volume = min(1,max(0,preferences.volume)); muted = preferences.muted; custom = preferences.custom
        }
    }
    func setVolume(_ value: Float) { guard value.isFinite else { return }; volume = min(1,max(0,value)); persist() }
    func setEnabled(_ event: AppSoundEvent, _ enabled: Bool) {
        if enabled { muted.remove(event) } else { muted.insert(event) }; persist()
    }
    func defaultURL(_ event: AppSoundEvent) -> URL? {
        Bundle.main.url(forResource:event.file,withExtension:"mp3",subdirectory:"Audio") ?? Bundle.main.url(forResource:event.file,withExtension:"mp3")
    }
    func importSound(_ url: URL, event: AppSoundEvent) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard (1...16_777_216).contains(size) else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try Data(contentsOf:url,options:.mappedIfSafe)
        let player = try AVAudioPlayer(data:bytes)
        guard player.duration.isFinite, player.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try bytes.write(to:customURL(event),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        custom.insert(event); persist()
    }
    func reset(_ event: AppSoundEvent) {
        try? FileManager.default.removeItem(at:customURL(event)); custom.remove(event); persist()
    }
    func play(_ event: AppSoundEvent) {
        guard volume > 0, !muted.contains(event) else { return }
        let own = custom.contains(event) ? try? Data(contentsOf:customURL(event),options:.mappedIfSafe) : nil
        var player = own.flatMap { try? AVAudioPlayer(data:$0) }
        if player == nil {
            if bundled[event] == nil, let url = defaultURL(event) { bundled[event] = try? Data(contentsOf:url) }
            if let bytes = bundled[event] { player = try? AVAudioPlayer(data:bytes) }
        }
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient,options:[.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = volume; player.delegate = self; player.prepareToPlay()
        if players.count >= 4 { players.removeFirst().stop() }
        players.append(player)
        if !player.play() { players.removeAll { $0 === player } }
    }
    /// iOS notifications use a local CAF shorter than 30 seconds. Render the
    /// selected sample with the same app-volume gain; mute also applies here.
    func notificationSound(_ event: AppSoundEvent) -> UNNotificationSound? {
        guard volume > 0, !muted.contains(event) else { return nil }
        let source = custom.contains(event) && FileManager.default.fileExists(atPath:customURL(event).path) ? customURL(event) : defaultURL(event)
        guard let source else { return .default }
        do {
            let data = try Data(contentsOf:source)
            let name = "entrixy-"+event.rawValue+"-"+String(GuestCrypto.hash(data+Data(String(volume).utf8)).prefix(20))+".caf"
            try FileManager.default.createDirectory(at:notificationDirectory,withIntermediateDirectories:true)
            let destination = notificationDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:destination.path) {
                let input = try AVAudioFile(forReading:source,commonFormat:.pcmFormatFloat32,interleaved:false)
                let count = AVAudioFrameCount(max(0,min(input.length,AVAudioFramePosition(input.processingFormat.sampleRate*29))))
                guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:count) else { return .default }
                try input.read(into:buffer,frameCount:count)
                if let channels = buffer.floatChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) { for frame in 0..<Int(buffer.frameLength) { channels[channel][frame] *= volume } }
                }
                let temporary = notificationDirectory.appendingPathComponent(UUID().uuidString+".caf")
                defer { try? FileManager.default.removeItem(at:temporary) }
                let settings: [String:Any] = [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:buffer.format.sampleRate,
                    AVNumberOfChannelsKey:buffer.format.channelCount,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false]
                do {
                    let output = try AVAudioFile(forWriting:temporary,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
                    try output.write(from:buffer)
                }
                try FileManager.default.moveItem(at:temporary,to:destination)
                // Bound generated notification cache without removing the sample
                // which this immediate notification is about to use.
                let old = (try? FileManager.default.contentsOfDirectory(at:notificationDirectory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
                let cached = old.filter { $0.lastPathComponent.hasPrefix("entrixy-") && $0 != destination }.sorted {
                    ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                for file in cached.dropFirst(15) { try? FileManager.default.removeItem(at:file) }
            }
            return UNNotificationSound(named:UNNotificationSoundName(rawValue:name))
        } catch { return .default }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { players.removeAll { $0 === player } }
    private func customURL(_ event: AppSoundEvent) -> URL { directory.appendingPathComponent(event.rawValue+".audio") }
    private func persist() {
        if let data = try? JSONEncoder().encode(AppSoundPreferences(volume:volume,muted:muted,custom:custom)) { defaults.set(data,forKey:key) }
    }
}

struct SoundSettingsRows: View {
    @ObservedObject var sounds = AppSoundCenter.shared
    @State private var volume: Float = AppSoundCenter.shared.volume
    @State private var importing: AppSoundEvent?
    @State private var choosingFile = false
    @State private var message: String?
    var body: some View {
        Group {
            Section {
                VStack(alignment:.leading,spacing:12) {
                    HStack(spacing:10) {
                        Image(systemName:"speaker.wave.2")
                        Text(ProductText.string("settings_sound_master_volume")).font(.subheadline.weight(.semibold))
                        Spacer(minLength:4); Text("\(Int(volume*100))% ").font(.subheadline).foregroundStyle(Brand.secondaryInk)
                    }
                    Slider(value:$volume,in:0...1,onEditingChanged:{ editing in if !editing { sounds.setVolume(volume) } }).tint(Brand.ink)
                }.padding(.vertical,4)
            }
            ForEach(AppSoundEvent.allCases) { event in
                Section {
                    HStack(spacing:8) {
                        Button { sounds.play(event) } label: { Image(systemName:"play.fill").font(.system(size:30)).frame(width:44,height:48) }
                            .buttonStyle(.plain).foregroundStyle(Brand.ink).disabled(sounds.muted.contains(event))
                            .accessibilityLabel(event.title)
                        VStack(alignment:.leading,spacing:5) {
                            Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(sounds.muted.contains(event) ? Brand.secondaryInk : Brand.ink)
                            Text(ProductText.string(sounds.muted.contains(event) ? "settings_sound_muted" : sounds.custom.contains(event) ? "settings_sound_custom_label" : "settings_sound_default"))
                                .font(.caption).foregroundStyle(Brand.secondaryInk)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        if !sounds.muted.contains(event) {
                            Button { importing = event; choosingFile = true } label: { Image(systemName:"square.and.arrow.up").font(.system(size:22)).frame(width:44,height:44) }
                                .buttonStyle(.plain).accessibilityLabel(ProductText.string("settings_sound_upload"))
                            if sounds.custom.contains(event) {
                                Button { sounds.reset(event) } label: { Image(systemName:"arrow.counterclockwise").font(.system(size:21)).frame(width:44,height:44) }
                                    .buttonStyle(.plain).accessibilityLabel(ProductText.string("settings_sound_reset"))
                            }
                        }
                        Toggle(event.title,isOn:Binding(get:{ !sounds.muted.contains(event) },set:{ sounds.setEnabled(event,$0) })).labelsHidden().fixedSize()
                    }.foregroundStyle(Brand.ink).padding(.vertical,4)
                }
            }
            if let message { Section { Text(message).foregroundStyle(.red) } }
        }
        .fileImporter(isPresented:$choosingFile,allowedContentTypes:[.audio]) { result in
            guard let importing else { return }
            do { try sounds.importSound(result.get(),event:importing); message = nil }
            catch {
                if (error as? CocoaError)?.code != .userCancelled { message = "Не удалось загрузить звук. Выберите доступный аудиофайл, который поддерживает iPhone." }
            }
            self.importing = nil
        }
    }
}
