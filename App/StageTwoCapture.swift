#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import EntrixyCore

enum StageTwoCapture: String, CaseIterable {
    case empty, guestControl = "guest-control", guestKeys = "guest-keys", keyDetail = "key-detail"
    case ownerObjects = "owner-objects", ownerGuests = "owner-guests", delegatingGuests = "delegating-guests"
    case system, codeSettings = "code-settings", sounds, addKey = "add-key", addServer = "add-server", journal
    static var current: Self? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--stage-two"), args.indices.contains(i + 1) else { return nil }
        return Self(rawValue: args[i + 1])
    }
    var settingsTab: SettingsTab {
        switch self {
        case .guestKeys, .keyDetail, .addKey: return .keys
        case .system, .codeSettings: return .system
        case .sounds: return .sounds
        default: return .objects
        }
    }
    var mainTab: AppTab {
        switch self { case .guestControl: return .control; case .ownerGuests, .delegatingGuests: return .guests; case .journal: return .journal; default: return .settings }
    }
    var isOwner: Bool { [.ownerObjects, .ownerGuests, .addServer].contains(self) }
    var isEmpty: Bool { [.empty, .addKey].contains(self) }
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
        var state = SavedState(identity: Data(repeating: 83, count: 32), guests: [])
        if !route.isEmpty && !route.isOwner {
            let invite = try! GuestInvite.parse("https://controller.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
            let object = try! JSONDecoder().decode(GuestObject.self, from: Data(#"{"id":"7","numberID":7,"kind":"device","label":"Ворота во двор","avatarType":"preset:3"}"#.utf8))
            var guest = SavedGuest(invite: invite, objects: [object])
            guest.incomingDepth = route == .delegatingGuests ? 1 : 0
            state.guests = [guest]
        }
        if route.isOwner {
            var owner = try! OwnerAccount(importing: "controller.invalid", masterKey: Data(repeating: 22, count: 32), credentials: OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64)))
            var object = try! OwnerObject(masterKey: owner.masterKey, label: "Ворота во двор", kind: "webhook", url: "https://actuator.invalid/open", secret: "public-capture-secret")
            object.numberID = 7; object.pending = nil; object.available = true
            owner.objects = [object]; state.owners = [owner]
        }
        _model = StateObject(wrappedValue: AppModel(storage: StageTwoStorage(state)))
    }
    var body: some View {
        RootView(initialTab: route.mainTab, showAddKey: route == .addKey)
            .environmentObject(model)
            .preferredColorScheme(.light)
            .task {
                // Production RootView and screens; fixture data never calls resume/bind/send.
                let status: [String: Any] = ["ready": model.storageReady, "route": route.rawValue,
                    "tabs": model.navigationState.tabs.map(\.rawValue), "owners": model.owners.count,
                    "guests": model.guests.count, "journal": model.journal.count, "product_routes": true]
                let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("stage-two-status.json")
                if let bytes = try? JSONSerialization.data(withJSONObject: status) { try? bytes.write(to: path, options: .atomic) }
            }
    }
}
#endif
