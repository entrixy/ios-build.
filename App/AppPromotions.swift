import Foundation
import SwiftUI
import ImageIO
import EntrixyCore

protocol PromotionStorage {
    func load() throws -> PromotionState
    func save(_ state:PromotionState) throws
}

struct FilePromotionStorage: PromotionStorage {
    private func file() throws -> URL {
        var root = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("Promotions",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        return root.appendingPathComponent("state.json")
    }
    func load() throws -> PromotionState {
        let url = try file()
        guard FileManager.default.fileExists(atPath:url.path) else {
            let state = PromotionState(); try save(state); return state
        }
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        let data = try handle.read(upToCount:262145) ?? Data()
        guard data.count <= 262144 else { throw GuestCrypto.Failure.invalidEnvelope }
        let state = try JSONDecoder().decode(PromotionState.self,from:data); try state.validate(); return state
    }
    func save(_ state:PromotionState) throws {
        try state.validate()
        try JSONEncoder().encode(state).write(to:file(),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor final class AppPromotions: ObservableObject {
    @Published private(set) var promotion: Promotion?
    private unowned let app: AppModel
    private let storage: PromotionStorage
    private let api: PromotionTransport
    private var state: PromotionState?
    private var active = false
    private var generation = UUID()
    private var loading: Task<Void,Never>?
    private var reporting: Task<Void,Never>?
    private var reportToken = UUID()
    private var images: ServerHTTPSession?
    init(app:AppModel,storage:PromotionStorage = FilePromotionStorage(),api:PromotionTransport = PromotionAPI()) {
        self.app = app; self.storage = storage; self.api = api
        images = Self.imageSession()
        // No storage UUID or network is created just by rendering a test route.
    }
    private static func imageSession() -> ServerHTTPSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false; settings.urlCache = nil
        settings.timeoutIntervalForRequest = 15; settings.timeoutIntervalForResource = 30
        return ServerHTTPSession(configuration:settings)
    }
    func activate() {
        active = true
        guard app.canManageGuestAccess, loading == nil else { return }
        if images == nil { images = Self.imageSession() }
        do {
            if state == nil { let loaded = try storage.load(); try loaded.validate(); state = loaded }
            promotion = state?.visible
            let currentLanguage = ProductText.language
            guard let state, state.cachedLanguage != currentLanguage || state.needsRefresh(now:Date()) else { return }
            var tags = Set<String>()
            let objects = app.owners.flatMap { $0.objects ?? [] }
            for kind in ["call","webhook","device"] where objects.contains(where:{ $0.kind == kind }) { tags.insert("has_" + kind) }
            if !app.guests.isEmpty { tags.insert("has_guest") }
            let body = try state.request(language:currentLanguage,version:Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",tags:tags,now:Date())
            let token = generation
            loading = Task { [weak self] in
                guard let self else { return }
                defer { if generation == token { loading = nil } }
                do {
                    let record = try await api.fetch(body)
                    try Task.checkCancellation()
                    guard active,generation == token,app.canManageGuestAccess,var draft = self.state else { return }
                    draft.cached = record; draft.cachedAt = Date(); draft.cachedLanguage = currentLanguage
                    try storage.save(draft); self.state = draft; promotion = draft.visible
                } catch { /* Keep the existing catalogue while offline. */ }
            }
        } catch { promotion = nil } // Never replace an unreadable installation identity.
    }
    func pause() {
        active = false; generation = UUID(); loading?.cancel(); loading = nil
        reportToken = UUID(); reporting?.cancel(); reporting = nil
        images?.invalidate(); images = nil
    }
    func languageChanged() { if active { activate() } }
    func viewed(id:Int) {
        guard active,app.canManageGuestAccess,var draft = state,promotion?.id == id else { return }
        let key = String(id)
        if draft.views[key] == nil && draft.views.count >= 1000 { return }
        draft.views[key] = min(10000,(draft.views[key] ?? 0)+1)
        do { try storage.save(draft); state = draft } catch { return }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from:Date())
        guard reporting == nil,draft.sentDay != today else { return }
        // The server caps each report at50; retain any unsent remainder.
        let count = min(50,draft.views[key] ?? 0), install = draft.installID, token = reportToken
        reporting = Task { [weak self] in
            guard let self else { return }
            defer { if reportToken == token { reporting = nil } }
            do {
                try await api.view(id:id,count:count,installID:install)
                try Task.checkCancellation()
                guard active,reportToken == token,var current = state,current.installID == install else { return }
                current.views[key] = max(0,(current.views[key] ?? 0)-count); current.sentDay = today
                try storage.save(current); state = current
            } catch { /* Retain the acknowledged-count boundary for the next view. */ }
        }
    }
    func clicked(id:Int) -> URL? {
        guard active,app.canManageGuestAccess,promotion?.id == id,let destination = promotion?.destination,var draft = state else { return nil }
        draft.clicked.removeAll { $0 == id }; draft.clicked.append(id); draft.clicked = Array(draft.clicked.suffix(1000))
        do { try storage.save(draft); state = draft; promotion = draft.visible; return destination } catch { return nil }
    }
    func image(_ url:URL) async throws -> UIImage {
        guard active,app.canManageGuestAccess,[promotion?.iconURL,promotion?.bannerURL].contains(url) else { throw URLError(.cancelled) }
        guard let images else { throw URLError(.cancelled) }
        let (bytes,response) = try await images.session(for:url).bytes(from:url)
        guard let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode),
              http.mimeType?.hasPrefix("image/") == true else { throw GuestCrypto.Failure.invalidEnvelope }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4_194_304 else { throw GuestCrypto.Failure.invalidEnvelope }; data.append(byte)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width),(1...8192).contains(height),width*height <= 16_777_216,
              let image = UIImage(data:data),active,app.canManageGuestAccess else { throw GuestCrypto.Failure.invalidEnvelope }
        return image
    }
}

struct PromotionCard: View {
    @ObservedObject var service: AppPromotions
    @Environment(\.openURL) private var openURL
    private func color(_ text:String?,fallback:Color) -> Color {
        guard let text,text.hasPrefix("#"),[7,9].contains(text.count),let raw = UInt64(text.dropFirst(),radix:16) else { return fallback }
        let alpha = text.count == 9 ? Double((raw>>24)&255)/255 : 1
        return Color(.sRGB,red:Double((raw>>16)&255)/255,green:Double((raw>>8)&255)/255,blue:Double(raw&255)/255,opacity:alpha)
    }
    private func clicked(_ promo:Promotion) { if let url = service.clicked(id:promo.id) { openURL(url) } }
    var body: some View {
        if let promo = service.promotion {
            Group {
                if let banner = promo.bannerURL {
                    PromotionPicture(service:service,url:banner,height:CGFloat(promo.height)) { clicked(promo) }
                        .accessibilityLabel(promo.title)
                } else {
                    HStack(spacing:12) {
                        if let icon = promo.iconURL { PromotionPicture(service:service,url:icon,height:72).frame(width:72) }
                        VStack(alignment:.leading,spacing:2) {
                            Text(promo.title).font(.system(size:16,weight:.semibold)).accessibilityIdentifier("promotion-title")
                            if let body = promo.body { Text(body).font(.system(size:12)).opacity(0.8).lineLimit(4) }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        if let button = promo.buttonText {
                            Button { clicked(promo) } label: { Text(button).font(.subheadline.weight(.semibold)) }
                                .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("promotion-action")
                                .fixedSize(horizontal:true,vertical:false)
                        }
                    }.padding(14).foregroundStyle(color(promo.textColor,fallback:.white))
                        .background(color(promo.backgroundColor,fallback:Color(red:26/255,green:86/255,blue:168/255)),in:RoundedRectangle(cornerRadius:16))
                        .contentShape(RoundedRectangle(cornerRadius:16))
                        .onTapGesture { if promo.buttonText == nil { clicked(promo) } }
                }
            }.task(id:promo.id) { service.viewed(id:promo.id) }
        }
    }
}

private struct PromotionPicture: View {
    let service: AppPromotions
    let url: URL
    let height: CGFloat
    var action: (() -> Void)? = nil
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage:image).resizable().scaledToFill().frame(maxWidth:.infinity).frame(height:height).clipped()
                    .clipShape(RoundedRectangle(cornerRadius:14)).contentShape(Rectangle()).onTapGesture { action?() }
            }
        }.task(id:url) { image = nil; image = try? await service.image(url) }
    }
}
