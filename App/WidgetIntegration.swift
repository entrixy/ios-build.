import Foundation
import UIKit
import WidgetKit
import EntrixyCore

extension Notification.Name { static let entrixyWidgetAction = Notification.Name("entrixy.widget.action") }

/// Only AppIntent.perform in the application process can enqueue an action.
/// The URL handler deliberately has no widget-fire route. No action is stored
/// in the shared container, restored from backup or replayed after a restart.
@MainActor final class WidgetActionInbox {
    static let shared = WidgetActionInbox()
    private weak var app: AppModel?
    private var queue = WidgetTapQueue()
    private var task: Task<Void,Never>?
    private var taskGeneration = UUID()
    private var dispatching = false
    private var ready = false
    private let now: () -> Date
    private let automaticallyDispatches: Bool
    init(automaticallyDispatches: Bool = true, now: @escaping () -> Date = Date.init) {
        self.automaticallyDispatches = automaticallyDispatches; self.now = now
    }
    func bind(_ app: AppModel) { self.app = app }
    func setReady(_ value: Bool) { ready = value; if value { start() } }
    @discardableResult func enqueue(_ objectID: String, id: UUID = UUID()) -> Bool {
        guard !dispatching, app?.hasTaskDialog != true,
              queue.enqueue(objectID:objectID,id:id,at:now()) else { return false }
        start(); return true
    }
    func cancel() { ready = false; queue.cancel(); taskGeneration = UUID(); task?.cancel(); task = nil }
    private func start() {
        guard automaticallyDispatches, task == nil, queue.pending != nil else { return }
        let generation = UUID(); taskGeneration = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.dispatchPending()
                if self.queue.current(at:self.now()) == nil {
                    if self.taskGeneration == generation { self.task = nil }
                    return
                }
                do { try await Task.sleep(nanoseconds:200_000_000) } catch { return }
            }
        }
    }
    func dispatchPending() async {
        guard !dispatching, let tap = queue.current(at:now()), ready, let app,
              app.canManageGuestAccess, !app.busy, !app.ownerBusy, !app.hasTaskDialog else { return }
        // Claim once before looking up readiness or entering an async transport.
        // Rejection is final for this invocation; it cannot later fire on resume.
        guard queue.consume(tap.id,at:now()) != nil else { return }
        dispatching = true; defer { dispatching = false }
        NotificationCenter.default.post(name:.entrixyWidgetAction,object:nil)
        await app.performWidgetTap(tap.objectID)
    }
}

extension AppModel {
    func performWidgetTap(_ objectID: String) async {
        guard canManageGuestAccess, !busy, !ownerBusy, !hasTaskDialog,
              let entry = controlObjects.first(where:{ WidgetObjectID.forTarget($0.target) == objectID }) else { return }
        switch entry {
        case let .owned(owner,object):
            guard let intent = ownerActionIntent(server:owner.server,objectID:object.id) else { return }
            if intent.policy.confirmation || intent.policy.authentication != nil { actionPrompt = .owner(intent) }
            else { AppSoundCenter.shared.play(.widget_fire); await execute(intent) }
        case let .received(guest,object):
            guard let intent = actionIntent(guestID:guest.id,object:object) else { return }
            if intent.policy.confirmation || intent.policy.authentication != nil { actionPrompt = .guest(intent) }
            else { AppSoundCenter.shared.play(.widget_fire); await execute(intent) }
        }
    }
}

@MainActor final class WidgetPresentationPublisher {
    private let directory: URL?
    private var previous: WidgetCatalog?
    init(directory: URL? = WidgetCatalog.directory) { self.directory = directory }
    @discardableResult func publish(_ app: AppModel, forceOffline: Bool = false) throws -> WidgetCatalog {
        var images: [String:Data] = [:]
        let date = Date()
        let objects: [WidgetObject] = app.storageReady ? app.controlObjects.map { entry in
            let preset = app.avatarPreset(entry.target) ?? 0
            var bytes: Data?
            switch entry {
            case let .owned(owner,object): bytes = try? object.avatar(masterKey:owner.masterKey)
            case let .received(guest,object):
                bytes = app.localAvatar(entry.target)
                if bytes == nil, app.objectPreferences.presentation(for:entry.target).avatarPreset == nil, object.avatarType == "file" {
                    bytes = app.avatars[AvatarCache.key(guestID:guest.id,objectID:object.id)]
                }
            }
            var imageName: String?
            if let bytes, let image = UIImage(data:bytes), image.size.width > 0, image.size.height > 0 {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let thumb = UIGraphicsImageRenderer(size:CGSize(width:96,height:96),format:format).image { _ in
                    let scale = max(96/image.size.width,96/image.size.height)
                    let size = CGSize(width:image.size.width*scale,height:image.size.height*scale)
                    image.draw(in:CGRect(x:(96-size.width)/2,y:(96-size.height)/2,width:size.width,height:size.height))
                }
                if let jpeg = thumb.jpegData(compressionQuality:0.7), jpeg.count <= 32768, images.count < 1000 {
                    imageName = GuestCrypto.hash(jpeg); images[imageName!] = jpeg
                }
            }
            let status: WidgetObject.Status
            let localCall: Bool
            if case .owned = entry { localCall = entry.kind == "call" } else { localCall = false }
            switch app.objectAvailability(entry) {
            case .ready: status = forceOffline && !localCall ? .offline : .ready
            case .connecting: status = forceOffline ? .offline : .connecting
            case .neutral: status = .neutral
            default: status = .offline
            }
            return WidgetObject(id:WidgetObjectID.forTarget(entry.target),label:app.objectLabel(entry),
                source:ProductText.string(entry.sourceLabel),preset:preset,image:imageName,status:status,localCall:localCall,observedAt:date)
        } : []
        let catalog = WidgetCatalog(objects:objects)
        guard objects.count <= 4000, objects.allSatisfy({ $0.validate() }) else { throw CocoaError(.fileWriteInvalidFileName) }
        // Refresh observations at most once every 10 seconds; structural edits
        // and disconnects are published immediately. WidgetKit controls reloads.
        if let previous, samePresentation(previous,catalog),
           let observed = previous.objects.first?.observedAt, date.timeIntervalSince(observed) < 10 { return previous }
        guard var directory else { return catalog }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(catalog)
        guard data.count <= 8_388_608 else { throw CocoaError(.fileWriteOutOfSpace) }
        for (name,bytes) in images {
            let url = directory.appendingPathComponent(name+".jpg")
            if !FileManager.default.fileExists(atPath:url.path) {
                try bytes.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        try data.write(to:directory.appendingPathComponent("catalog.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        previous = catalog
        // Old snapshots may still reference a removed image; a missing thumbnail
        // uses the same original preset-zero fallback as the app and Android.
        for url in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
            where url.pathExtension == "jpg" && images[url.deletingPathExtension().lastPathComponent] == nil { try? FileManager.default.removeItem(at:url) }
        WidgetCenter.shared.reloadTimelines(ofKind:WidgetCatalog.kind)
        return catalog
    }
    private func samePresentation(_ lhs: WidgetCatalog,_ rhs: WidgetCatalog) -> Bool {
        guard lhs.objects.count == rhs.objects.count else { return false }
        return zip(lhs.objects,rhs.objects).allSatisfy { a,b in
            a.id == b.id && a.label == b.label && a.source == b.source && a.preset == b.preset && a.image == b.image && a.status == b.status && a.localCall == b.localCall
        }
    }
}
