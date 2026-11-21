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
    var generation: String? = nil
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
    private var generation: String?
    init(defaults: UserDefaults = .standard, directory: URL? = nil, notificationDirectory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EventSounds",isDirectory:true)
        self.notificationDirectory = notificationDirectory ?? FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask)[0].appendingPathComponent("Sounds",isDirectory:true)
        super.init()
        if let bytes = defaults.data(forKey:key), let preferences = try? JSONDecoder().decode(AppSoundPreferences.self,from:bytes), preferences.volume.isFinite,
           preferences.generation.map({ UUID(uuidString:$0) != nil }) ?? true {
            volume = min(1,max(0,preferences.volume)); muted = preferences.muted; custom = preferences.custom
            generation = preferences.generation
        }
    }
    func setVolume(_ value: Float) { guard value.isFinite else { return }; volume = min(1,max(0,value)); persist() }
    func clearAfterLocalReset() {
        players.forEach { $0.stop() }; players.removeAll()
        volume = 0.1; muted.removeAll(); custom.removeAll(); generation = nil
    }
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
        let bytes = try Self.readSampleFile(url)
        let player = try AVAudioPlayer(data:bytes)
        guard player.duration.isFinite, player.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at:customURL(event).deletingLastPathComponent(),withIntermediateDirectories:true)
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
    struct RestoreStage {
        fileprivate let generation: String
        fileprivate let material: EventSoundBackup
        fileprivate let root: URL
    }
    func backupMaterial() throws -> EventSoundBackup {
        var samples: [String:Data] = [:], missing = Set<String>()
        for event in custom {
            let url = customURL(event)
            guard FileManager.default.fileExists(atPath:url.path) else { missing.insert(event.rawValue); continue }
            let data = try Self.readSampleFile(url)
            try Self.validateSample(data)
            samples[event.rawValue] = data
        }
        return try EventSoundBackup(volume:volume,muted:Set(muted.map(\.rawValue)),samples:samples,unavailableSamples:missing)
    }
    static func validateBackup(_ material: EventSoundBackup) throws {
        try material.validate()
        for sample in material.samples.values { try validateSample(sample) }
    }
    private static func validateSample(_ bytes: Data) throws {
        let player = try AVAudioPlayer(data:bytes)
        guard player.duration.isFinite, player.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
    private static func readSampleFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount:65536), !chunk.isEmpty {
            guard data.count + chunk.count <= BackupEnvelope.maxPayloadSize else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    /// Stage a complete generation before ownership moves. A corrupt sample or
    /// disk write failure cannot replace any currently selected user file.
    func prepareRestore(_ material: EventSoundBackup) throws -> RestoreStage {
        try Self.validateBackup(material)
        let stage = RestoreStage(generation:UUID().uuidString,material:material,root:directory)
        let folder = directory.appendingPathComponent(stage.generation,isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for (event,data) in material.samples { try data.write(to:folder.appendingPathComponent(event+".audio"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
            return stage
        } catch { try? FileManager.default.removeItem(at:folder); throw error }
    }
    func discardUnusedRestore(_ stage: RestoreStage) {
        if generation != stage.generation { try? FileManager.default.removeItem(at:directory.appendingPathComponent(stage.generation,isDirectory:true)) }
    }
    func commitRestore(_ stage: RestoreStage,commitAccess: () throws -> Void) throws {
        guard stage.root == directory else { throw CocoaError(.fileReadCorruptFile) }
        for (event,data) in stage.material.samples {
            let staged = directory.appendingPathComponent(stage.generation,isDirectory:true).appendingPathComponent(event+".audio")
            guard try Self.readSampleFile(staged) == data else { throw CocoaError(.fileReadCorruptFile) }
        }
        let previous = AppSoundPreferences(volume:volume,muted:muted,custom:custom,generation:generation)
        players.forEach { $0.stop() }; players.removeAll()
        generation = stage.generation; volume = stage.material.volume
        muted = Set(stage.material.muted.compactMap(AppSoundEvent.init(rawValue:)))
        custom = Set(stage.material.samples.keys.compactMap(AppSoundEvent.init(rawValue:)))
        persist()
        do { try commitAccess() }
        catch {
            generation = previous.generation; volume = previous.volume; muted = previous.muted; custom = previous.custom; persist()
            throw error
        }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { players.removeAll { $0 === player } }
    private func customURL(_ event: AppSoundEvent) -> URL { (generation.map { directory.appendingPathComponent($0,isDirectory:true) } ?? directory).appendingPathComponent(event.rawValue+".audio") }
    private func persist() {
        if let data = try? JSONEncoder().encode(AppSoundPreferences(volume:volume,muted:muted,custom:custom,generation:generation)) { defaults.set(data,forKey:key) }
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
                    Slider(value:$volume,in:0...1,onEditingChanged:{ editing in if !editing { sounds.setVolume(volume) } }).tint(AppPalette.selected)
                }.padding(.vertical,4)
            }
            ForEach(AppSoundEvent.allCases) { event in
                Section {
                    HStack(spacing:8) {
                        Button { sounds.play(event) } label: { Image(systemName:"play.fill").resizable().scaledToFit().frame(width:24,height:24) }
                            .buttonStyle(SquareIconActionStyle()).disabled(sounds.muted.contains(event))
                            .accessibilityLabel(event.title)
                        VStack(alignment:.leading,spacing:5) {
                            Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(sounds.muted.contains(event) ? Brand.secondaryInk : Brand.ink)
                            Text(ProductText.string(sounds.muted.contains(event) ? "settings_sound_muted" : sounds.custom.contains(event) ? "settings_sound_custom_label" : "settings_sound_default"))
                                .font(.caption).foregroundStyle(Brand.secondaryInk)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        if !sounds.muted.contains(event) {
                            Button { importing = event; choosingFile = true } label: { Image("android-upload-file").resizable().scaledToFit().frame(width:24,height:24) }
                                .buttonStyle(SquareIconActionStyle()).accessibilityLabel(ProductText.string("settings_sound_upload"))
                            if sounds.custom.contains(event) {
                                Button { sounds.reset(event) } label: { Image(systemName:"arrow.counterclockwise").resizable().scaledToFit().frame(width:24,height:24) }
                                    .buttonStyle(SquareIconActionStyle()).accessibilityLabel(ProductText.string("settings_sound_reset"))
                            }
                        }
                        Toggle(event.title,isOn:Binding(get:{ !sounds.muted.contains(event) },set:{ sounds.setEnabled(event,$0) })).labelsHidden().fixedSize()
                    }.foregroundStyle(Brand.ink).padding(.vertical,4)
                }
            }
            if let message { Section { Text(ProductText.systemMessage(message)).foregroundStyle(.red) } }
        }
        .fileImporter(isPresented:$choosingFile,allowedContentTypes:[.audio]) { result in
            guard let importing else { return }
            do { try sounds.importSound(result.get(),event:importing); message = nil }
            catch {
                if (error as? CocoaError)?.code != .userCancelled { message = ProductText.string("ios_sound_import_failed") }
            }
            self.importing = nil
        }
        .onChange(of:sounds.volume) { volume = $0 }
    }
}
