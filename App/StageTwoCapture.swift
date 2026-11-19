#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import EntrixyCore

enum StageTwoCapture: String, CaseIterable {
    case empty, guestControl = "guest-control", guestKeys = "guest-keys", keyDetail = "key-detail"
    case ownerObjects = "owner-objects", ownerGuests = "owner-guests", delegatingGuests = "delegating-guests"
    case system, codeSettings = "code-settings", sounds, addKey = "add-key", addServer = "add-server", journal
    case ownerExpanded = "owner-expanded", guestExpanded = "guest-expanded", addObject = "add-object"
    case objectDelete = "object-delete"
    case ownerControl = "owner-control", mixedObjects = "mixed-objects"
    case ownerConfirmation = "owner-confirmation", ownerCodeConfirmation = "owner-code-confirmation"
    case deviceClaim = "device-claim"
    case ownerBLEObjects = "owner-ble-objects"
    case ownerCallGuests = "owner-call-guests", ownerDeviceObjects = "owner-device-objects"
    case networkPrivacy = "network-privacy"
    case diagnostics
    case keyAccepted = "key-accepted"
    case ownerIssued = "owner-issued"
    case incomingMessage = "incoming-message"
    case promotion
    @MainActor static func offlinePromotions(for app:AppModel) -> AppPromotions {
        AppPromotions(app:app,storage:StagePromotionStorage(empty:true),api:StagePromotionAPI())
    }
    static var current: Self? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--stage-two"), args.indices.contains(i + 1) else { return nil }
        return Self(rawValue: args[i + 1])
    }
    var settingsTab: SettingsTab {
        switch self {
        case .guestKeys, .keyDetail, .addKey: return .keys
        case .system, .codeSettings, .addServer, .networkPrivacy, .diagnostics: return .system
        case .sounds: return .sounds
        default: return .objects
        }
    }
    var mainTab: AppTab {
        switch self { case .guestControl, .ownerControl, .ownerConfirmation, .ownerCodeConfirmation, .keyAccepted, .incomingMessage, .promotion: return .control; case .ownerGuests, .delegatingGuests, .ownerIssued, .ownerCallGuests: return .guests; case .journal: return .journal; default: return .settings }
    }
    var isOwner: Bool { [.ownerObjects, .ownerGuests, .addServer, .ownerExpanded, .addObject, .objectDelete, .ownerControl, .mixedObjects, .ownerConfirmation, .ownerCodeConfirmation, .ownerBLEObjects, .ownerIssued, .promotion, .ownerCallGuests, .ownerDeviceObjects].contains(self) }
    var isEmpty: Bool { [.empty, .addKey, .deviceClaim].contains(self) }
}
private final class StageTwoStorage: StateStorage {
    var state: SavedState
    init(_ state: SavedState) { self.state = state }
    func load() throws -> SavedState? { state }
    func save(_ state: SavedState) throws { self.state = state }
}
struct StageTwoRoot: View {
    let route: StageTwoCapture
    @StateObject private var model: AppModel
    init(route: StageTwoCapture) {
        self.route = route
        // StateObject owns the fixture factory. View reconstruction must not
        // create discarded models or write UserDefaults observed by that view.
        _model = StateObject(wrappedValue:Self.makeModel(route:route))
    }
    @MainActor private static func makeModel(route:StageTwoCapture) -> AppModel {
        var state = SavedState(identity: Data(repeating: 83, count: 32), guests: [])
        if !route.isEmpty && (!route.isOwner || route == .mixedObjects) {
            let invite = try! GuestInvite.parse("https://controller.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
            let object = try! JSONDecoder().decode(GuestObject.self, from: Data(#"{"id":"7","numberID":7,"kind":"device","label":"Ворота во двор","avatarType":"preset:3"}"#.utf8))
            var guest = SavedGuest(invite: invite, objects: [object])
            if route == .mixedObjects {
                guest.objects = try! JSONDecoder().decode([GuestObject].self, from: Data(#"[{"id":"n:7","numberID":7,"kind":"device","label":"Гостевой въезд","avatarType":"preset:0"},{"id":"b:8","numberID":8,"kind":"ble","label":"Дверь Bluetooth","avatarType":"preset:2"}]"#.utf8))
            }
            guest.incomingDepth = route == .delegatingGuests ? 1 : 0
            if route == .keyAccepted { guest.welcome = "Добро пожаловать! Въезд со стороны двора."; guest.checkedAt = Date() }
            state.guests = [guest]
            if route == .incomingMessage {
                var message = SavedMessage(guestID:guest.id,cipher:try! GuestMessageCrypto.seal("Здравствуйте! Въезд со стороны двора. После проезда закройте ворота.",bundleKey:invite.bundleKey),receivedAt:Date())
                message.deliveryAcknowledged = true; state.incomingMessages = [message]
            }
        }
        if route.isOwner {
            var owner = try! OwnerAccount(importing: "controller.invalid", masterKey: Data(repeating: 22, count: 32), credentials: OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64)))
            let confirmationRoute = route == .ownerConfirmation || route == .ownerCodeConfirmation || route == .ownerCallGuests
            var object = try! OwnerObject(masterKey: owner.masterKey, label: "Ворота во двор", kind: confirmationRoute ? "call" : "webhook", phone: confirmationRoute ? "+10000000000" : "", url: confirmationRoute ? "" : "https://actuator.invalid/open", secret: confirmationRoute ? "" : "public-capture-secret")
            if route == .ownerBLEObjects {
                object = try! OwnerObject(importing:object.id,numberID:7,kind:"ble",cipher:object.cipher,wrappedKey:object.wrappedKey,masterKey:owner.masterKey,bleSecret:Data(repeating:9,count:32),bleDeviceID:123)
            }
            if route == .ownerDeviceObjects {
                object = try! OwnerObject(masterKey:owner.masterKey,label:"Ворота во двор",kind:"device",registerDevice:true)
                object.sent = true
                try! object.acceptDeviceRegistration(id:9,key:String(repeating:"c",count:32),secret:String(repeating:"d",count:32),masterKey:owner.masterKey)
            }
            object.numberID = 7; object.pending = nil; object.available = true; object.revision = 1
            if route == .ownerExpanded {
                // Configured rule data, never a simulated current GPS/network fix.
                var policy = try! AutomationTemplate(data:object.localPolicy)
                policy.geoLat = 55.75; policy.geoLon = 37.62
                policy.wifiConnectSsid = "Двор"; policy.wifiConnectBssid = "aa:bb:cc:dd:ee:ff"
                policy.wifiBssids = ["aa:bb:cc:dd:ee:ff"]; policy.wifiSsids = ["Двор"]; policy.wifiMinMatch = 1
                object.localPolicy = try! policy.data()
            }
            if route == .ownerConfirmation { object.localPolicy = Data(#"{"confirm_on":true}"#.utf8) }
            if route == .ownerCodeConfirmation { object.localPolicy = Data(#"{"auth_on":true,"auth":"pin"}"#.utf8) }
            owner.objects = [object]
            if route == .ownerIssued {
                var key = try! OwnerIssuedKey(owner:owner,label:"Анна",numberIDs:[7],welcome:"Добро пожаловать во двор.",nativeOnly:false,confirmation:false)
                key.keyID = 21; key.effectiveNumberIDs = [7]; key.state = .active; key.pending = nil; key.sent = true
                owner.issuedKeys = [key]
            }
            state.owners = [owner]
        }
        if route == .mixedObjects, let owner = state.owners?.first, let object = owner.objects?.first, let guest = state.guests.first {
            state.objectPreferences = ObjectCatalogPreferences(order: [
                .received(guestID: guest.id, objectID: "b:8"), .owned(server: owner.server, objectID: object.id),
                .received(guestID: guest.id, objectID: "n:7")])
        }
        if route == .networkPrivacy { state.networkPrivacy = try! NetworkPrivacyPreferences(own:[PrivacyNetwork(ssid:"Home fixture")]) }
        let app = AppModel(storage:StageTwoStorage(state),privacyRouter:route == .networkPrivacy ? ServerPrivacyRouter() : nil)
        if route == .promotion { app.promotions = AppPromotions(app:app,storage:StagePromotionStorage(),api:StagePromotionAPI()) }
        if route == .incomingMessage { app.messages = MessageManager(app:app,acknowledgements:StageMessageAcknowledgements()) }
        if route == .diagnostics {
            UserDefaults.standard.set(false,forKey:"entrixy.developerMode")
            app.diagnostics = AppDiagnostics(app:app,storage:StageDiagnosticStorage(),api:StageDiagnosticAPI(),usesMetricKit:false)
        }
        if route == .ownerConfirmation || route == .ownerCodeConfirmation || route == .ownerCallGuests {
            // No resume/live factory or actual telephone handoff in these UI routes.
            app.ownerControl = OwnerControlModel(app:app,dialer:{ _ in false })
        }
        if route == .delegatingGuests { app.passManager = PassManager(app:app,api:StageTwoDelegationAPI()) }
        return app
    }
    var body: some View {
        RootView(initialTab: route.mainTab, showAddKey: route == .addKey,
                 pendingURL:.constant(route == .deviceClaim ? URL(string:"https://factory.invalid:8443/claim?c=a1b2-c3d4") : nil))
            .environmentObject(model)
            .preferredColorScheme(.light)
            .task {
                // Production RootView and screens; fixture data never calls resume/bind/send.
                if route == .diagnostics { model.diagnostics.activate() }
                if route == .promotion { model.promotions.activate() }
                if route == .keyAccepted, let guest = model.guests.first { model.presentKeyAcceptance(guest.id) }
                if route == .objectDelete, let target = model.catalogObjects().first?.target { model.objectRemovalTarget = target }
                let status: [String: Any] = ["ready": model.storageReady, "route": route.rawValue,
                    "tabs": model.navigationState.tabs.map(\.rawValue), "owners": model.owners.count,
                    "guests": model.guests.count, "journal": model.journal.count, "product_routes": true]
                let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("stage-two-status.json")
                if let bytes = try? JSONSerialization.data(withJSONObject: status) { try? bytes.write(to: path, options: .atomic) }
            }
    }
}
private final class StageDiagnosticStorage: DiagnosticStorage {
    private var state = DiagnosticState()
    func load() throws -> DiagnosticState { state }
    func save(_ state: DiagnosticState) throws { try state.validate(); self.state = state }
}
private final class StagePromotionStorage: PromotionStorage {
    private var state: PromotionState = {
        var state = PromotionState()
        state.cached = try! Promotion(json:["id":7,"title":"Доступ для ваших гостей","body":"Передавайте ключи и настраивайте доступ для каждого объекта.","button_text":"Подробнее","button_url":"https://entrixy.com/guide/","display_mode":"until_click"])
        state.cachedAt = Date(); state.cachedLanguage = ProductText.language
        return state
    }()
    init(empty:Bool = false) { if empty { state.cached = nil } }
    func load() throws -> PromotionState { state }
    func save(_ state:PromotionState) throws { self.state = state }
}
private struct StagePromotionAPI: PromotionTransport {
    func fetch(_ body:Data) async throws -> Promotion? { throw URLError(.notConnectedToInternet) }
    func view(id:Int,count:Int,installID:UUID) async throws { }
}
private struct StageMessageAcknowledgements: GuestMessageTransport {
    func acknowledgeMessage(invite:GuestInvite,fingerprint:String,kind:MessageAcknowledgement,hash:String) async throws {}
}
private struct StageDiagnosticAPI: DiagnosticTransport {
    func send(_ report: DiagnosticReport) async throws { try report.validate() }
}
private struct StageTwoDelegationAPI: DelegationTransport {
    func delegate(invite: GuestInvite,fingerprint: String,operation: DelegationOperation,body: Data) async throws -> Data {
        guard operation == .list else { throw GuestCrypto.Failure.invalidEnvelope }
        return Data(#"{"objects":[{"id":7,"depth":1,"pool_left":3,"native_only":0}],"children":[],"invites":[]}"#.utf8)
    }
    func delegationInfo(server: String,group: String) async throws -> Data { throw GuestCrypto.Failure.invalidEnvelope }
    func redeemDelegation(_ pending: DelegationRedemption,fingerprint: String) async throws -> Data { throw GuestCrypto.Failure.invalidEnvelope }
    func resolveDelegation(_ pending: DelegationRedemption,part: DelegationRedemption.Part,fingerprint: String) async throws -> GuestInvite? { throw GuestCrypto.Failure.invalidEnvelope }
}
#endif
