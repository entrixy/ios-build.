#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import EntrixyCore

/// Standalone, explicitly labelled software-controller captures. No real bootstrap,
/// primary Keychain state, API binding or live WebSocket is used in this branch.
enum ActionCaptureScenario: String, CaseIterable {
    case confirmOpen = "confirm-open", confirmClose = "confirm-close"
    case codeSetup = "code-setup", codeEntry = "code-entry", codeRejected = "code-rejected"
    case biometric, requestSent = "request-sent", result, journal, offline
    case control, settings, guests, addKey = "add-key", keyDetail = "key-detail"
    case ownerForm = "owner-form", ownerReady = "owner-ready"
    case ownerUncertain = "owner-uncertain", ownerOffline = "owner-offline"
    case objectForm = "object-form", objectCreated = "object-created", objectEdit = "object-edit"
    case objectRenamed = "object-renamed", objectDelete = "object-delete-confirm", objectDeleted = "object-deleted", objectUncertain = "object-uncertain"
    case issueForm = "issue-form", issuedKey = "issued-key", issuedList = "issued-list", issuedPaused = "issued-paused"
    case issuedRevoked = "issued-revoked", issuedUncertain = "issued-uncertain", issuedRevokeConfirm = "issued-revoke-confirm"
    case ownerConfirm = "owner-confirm", ownerSending = "owner-sending", ownerResult = "owner-result", ownerJournal = "owner-journal", ownerGuestRequest = "owner-guest-request"
    case issuedEditForm = "issued-edit-form", issuedEditResult = "issued-edit-result"
    case backupForm = "backup-form", backupExport = "backup-export", backupPreview = "backup-preview"
    case backupRestored = "backup-restored", backupRejected = "backup-rejected", backupInterrupted = "backup-interrupted"
    case delegationPreview = "delegation-preview", delegationWaiting = "delegation-waiting"
    case delegationReady = "delegation-ready", delegationRejected = "delegation-rejected"
    case issuedAccessForm = "issued-access-form"
    case delegatedAwaiting = "delegated-awaiting", delegatedReady = "delegated-ready"
    case delegatedUncertain = "delegated-uncertain", delegatedRevoked = "delegated-revoked", delegatedUntrusted = "delegated-untrusted"
    case senderForm = "sender-form", senderLink = "sender-link", senderUncertain = "sender-uncertain"
    case senderVouched = "sender-vouched", senderRevoked = "sender-revoked", senderEditForm = "sender-edit-form", senderEdited = "sender-edited"
    case messageInbox = "message-inbox", messageRead = "message-read", messageCorrupt = "message-corrupt"
    case messageCompose = "message-compose", messageSent = "message-sent"
    case additionalParts = "additional-parts"
    case bleScan = "ble-scan", bleUncertain = "ble-uncertain", blePaired = "ble-paired", bleRegistered = "ble-registered"
    case bleOwnerConfirm = "ble-owner-confirm", bleOwnerResult = "ble-owner-result", bleOwnerUnknown = "ble-owner-unknown", bleOwnerJournal = "ble-owner-journal"
    case bleGuestConfirm = "ble-guest-confirm", bleGuestResult = "ble-guest-result", bleGuestExpired = "ble-guest-expired", bleGuestUnknown = "ble-guest-unknown", bleGuestJournal = "ble-guest-journal"
    case bleRevokePending = "ble-revoke-pending", bleRevokeApplied = "ble-revoke-applied", bleRevokeStale = "ble-revoke-stale", bleRenewed = "ble-renewed"
    var isBLELifecycle: Bool { [.bleRevokePending, .bleRevokeApplied, .bleRevokeStale, .bleRenewed].contains(self) }
    var usesTaskFooter: Bool {
        [.addKey, .ownerForm, .objectForm, .issueForm, .issuedEditForm, .issuedAccessForm,
         .senderForm, .senderEditForm, .messageCompose, .delegationPreview, .delegationRejected].contains(self)
    }
    var presentsPreparedTaskSheet: Bool { usesTaskFooter && self != .addKey }
    var taskBackgroundTab: AppTab { isIssuance || isSender ? .guests : (isDelegation ? .control : .settings) }
    var isBLEGuest: Bool { [.bleGuestConfirm, .bleGuestResult, .bleGuestExpired, .bleGuestUnknown, .bleGuestJournal].contains(self) }
    var isBLEOwner: Bool { [.bleOwnerConfirm, .bleOwnerResult, .bleOwnerUnknown, .bleOwnerJournal].contains(self) }
    var isBLEPairing: Bool { isBLELifecycle || isBLEOwner || [.bleScan, .bleUncertain, .blePaired, .bleRegistered].contains(self) }
    var isMessageIncoming: Bool { [.messageInbox, .messageRead, .messageCorrupt].contains(self) }
    var isSender: Bool { [.senderForm, .senderLink, .senderUncertain, .senderVouched, .senderRevoked, .senderEditForm, .senderEdited].contains(self) }
    var isOwnerDelegation: Bool { [.delegatedAwaiting, .delegatedReady, .delegatedUncertain, .delegatedRevoked, .delegatedUntrusted].contains(self) }
    var isDelegation: Bool { [.delegationPreview, .delegationWaiting, .delegationReady, .delegationRejected, .additionalParts].contains(self) }
    var isBackup: Bool { [.backupForm, .backupExport, .backupPreview, .backupRestored, .backupRejected, .backupInterrupted].contains(self) }
    var isOwnerControl: Bool { [.ownerConfirm, .ownerSending, .ownerResult, .ownerJournal, .ownerGuestRequest].contains(self) }
    var isIssuance: Bool { isOwnerDelegation || [.issueForm, .issuedKey, .issuedList, .issuedPaused, .issuedRevoked, .issuedUncertain, .issuedRevokeConfirm, .issuedEditForm, .issuedEditResult, .issuedAccessForm, .messageCompose, .messageSent].contains(self) }
    var isObject: Bool { [.objectForm, .objectCreated, .objectEdit, .objectRenamed, .objectDelete, .objectDeleted, .objectUncertain].contains(self) }
    var isOwner: Bool { isBLEPairing || isBackup || isObject || isIssuance || isOwnerControl || [.ownerForm, .ownerReady, .ownerUncertain, .ownerOffline].contains(self) }
    static var current: Self? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--capture-actions"), index + 1 < args.count else { return nil }
        return Self(rawValue: args[index + 1])
    }
}

private final class CaptureController: GuestActionTransport {
    private(set) var frames: [[String: Any]] = []
    func sendAction(_ frame: Data) async throws {
        guard let json = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        frames.append(json)
    }
    func close() {}
    func verifiedFire() -> Bool {
        guard frames.count == 2, frames[0]["type"] as? String == "call",
              let fire = frames.last, fire["type"] as? String == "sock_fire",
              fire["command_id"] as? String == "capture-command",
              let proof = fire["proof"] as? String, let bytes = Data(base64Encoded: proof) else { return false }
        // Independent Python hmac/hashlib vector: key 00..1f, nonce 00..0f.
        return bytes.map { String(format: "%02x", $0) }.joined() == "d8b99f2709a3ca74172cbe93824c1f29"
    }
}

private final class CaptureOwnerSocket: OwnerLiveTransport {
    let frames: AsyncThrowingStream<Data, Error>
    private let output: AsyncThrowingStream<Data, Error>.Continuation
    var onWrite: (([String: Any]) throws -> Void)?
    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        frames = AsyncThrowingStream { continuation = $0 }
        output = continuation
        emit(["type": "host_ok"])
    }
    func emit(_ json: [String: Any]) { if let bytes = try? JSONSerialization.data(withJSONObject: json) { output.yield(bytes) } }
    func sendAction(_ frame: Data) async throws {
        guard let json = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        try onWrite?(json)
    }
    func close() { output.finish() }
}

/// In-process test server; reserved domain and public fixture credentials only.
private final class CaptureOwnerServer: OwnerTransport {
    let uncertain: Bool
    var offline = false
    var loseCreateReply = false
    private(set) var mutations = 0
    private var rows: [[String: Any]] = []
    var keyRows: [[String: Any]] = []
    var loseKeyReply = false
    var loseKeyEditReply = false
    private(set) var keyMutations = 0
    private(set) var ownerWrites: [[String: Any]] = []
    private(set) var sockets: [CaptureOwnerSocket] = []
    var finishOwnerAction = false
    func live(server: String, credentials: OwnerCredentials, fingerprint: String) throws -> OwnerLiveTransport {
        guard server == "controller.invalid" else { throw GuestCrypto.Failure.invalidEnvelope }
        let socket = CaptureOwnerSocket()
        socket.onWrite = { [weak self, weak socket] json in
            guard let self else { return }
            self.ownerWrites.append(json)
            if json["type"] as? String == "host_self_webhook" {
                socket?.emit(["type": "device_sent", "number_id": 7, "call_id": "capture-owner-action"])
                if self.finishOwnerAction {
                    socket?.emit(["type": "device_status", "number_id": 7, "call_id": "capture-owner-action", "message": "Тестовый запрос владельца выполнен", "level": "success", "final": true])
                }
            }
        }
        sockets.append(socket)
        return socket
    }
    private(set) var messagesSent = 0
    private(set) var messageCipher: String?
    private(set) var registrations = 0
    private(set) var syncs = 0
    init(uncertain: Bool) { self.uncertain = uncertain }
    func register(server: String, accessCode: String) async throws -> OwnerCredentials {
        guard server == "controller.invalid" else { throw GuestCrypto.Failure.invalidEnvelope }
        registrations += 1
        if uncertain { throw URLError(.networkConnectionLost) }
        return try OwnerCredentials(deviceID: String(repeating: "a", count: 32), deviceSecret: String(repeating: "b", count: 64))
    }
    func sync(server: String, credentials: OwnerCredentials, fingerprint: String) async throws -> Data {
        guard server == "controller.invalid" else { throw GuestCrypto.Failure.invalidEnvelope }
        syncs += 1
        if offline { throw URLError(.notConnectedToInternet) }
        return try JSONSerialization.data(withJSONObject: ["numbers": rows, "keys": keyRows])
    }
    func mutate(server: String, credentials: OwnerCredentials, fingerprint: String, operation: OwnerOperation, body: Data) async throws -> Data {
        guard server == "controller.invalid", let request = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        mutations += 1
        switch operation {
        case .messageSend:
            guard let cipher = request["cipher"] as? String, request["user_key_id"] as? Int == 17 else { throw GuestCrypto.Failure.invalidEnvelope }
            messagesSent += 1; messageCipher = cipher
            return Data(#"{"ok":1}"#.utf8)
        case .hostClaim:
            if offline { throw URLError(.notConnectedToInternet) }
            return Data(#"{"ok":1,"claim":"moved"}"#.utf8)
        case .keyCreate:
            keyMutations += 1
            guard keyRows.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
            keyRows = [["id": 17, "enabled": 1, "mode": "auto", "sign_pub": request["sign_pub"]!, "number_ids": request["number_ids"]!, "bundle_cipher": request["bundle_cipher"]!, "objects": request["objects"]!]]
            if loseKeyReply { throw URLError(.networkConnectionLost) }
            return Data(#"{"id":17}"#.utf8)
        case .keyMode:
            keyMutations += 1
            keyRows[0]["mode"] = request["mode"]
        case .keyRevoke:
            keyMutations += 1
            let index = keyRows.firstIndex { ($0["id"] as? Int) == (request["id"] as? Int) } ?? 0
            keyRows[index]["enabled"] = 0
        case .keyEdit:
            keyMutations += 1
            let index = keyRows.firstIndex { ($0["id"] as? Int) == (request["id"] as? Int) } ?? 0
            keyRows[index]["bundle_cipher"] = request["bundle_cipher"]
            keyRows[index]["number_ids"] = request["number_ids"]
            if let objects = request["objects"] { keyRows[index]["objects"] = objects }
            if let cipher = request["key_cipher"] { keyRows[index]["key_cipher"] = cipher; keyRows[index]["needs_bundle"] = 0 }
            if loseKeyEditReply { throw URLError(.networkConnectionLost) }
        case .claim: return Data(#"{"device_id":9}"#.utf8)
        case .create:
            guard rows.isEmpty, let cipher = request["data_cipher"] as? String, let kind = request["type"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
            rows.append(["id": 7, "type": kind, "data_cipher": cipher, "data_cipher_revision": 100])
            if loseCreateReply { throw URLError(.networkConnectionLost) }
            return Data(#"{"id":7}"#.utf8)
        case .update:
            guard let i = rows.firstIndex(where: { ($0["id"] as? Int) == (request["id"] as? Int) }),
                  (request["data_cipher_ts_check"] as? Int) == (rows[i]["data_cipher_revision"] as? Int),
                  let cipher = request["data_cipher"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
            rows[i]["data_cipher"] = cipher
            rows[i]["data_cipher_revision"] = 101
        case .delete: rows.removeAll { ($0["id"] as? Int) == (request["id"] as? Int) }
        }
        return Data(#"{"ok":true}"#.utf8)
    }
}
private final class CaptureDelegationServer: DelegationTransport {
    var reject = false
    var ready = false
    var extraPart = false
    var redeems = 0
    var resolves = 0
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data { throw GuestCrypto.Failure.invalidEnvelope }
    func delegationInfo(server: String, group: String) async throws -> Data {
        guard server == "controller.invalid", !reject else { throw URLError(.notConnectedToInternet) }
        var parts = [["code": String(repeating: "B", count: 22), "state": extraPart ? "redeemed" : "new"]]
        if extraPart { parts.append(["code": String(repeating: "C", count: 22), "state": "new"]) }
        return try JSONSerialization.data(withJSONObject: ["grp": group, "state": "new", "parts": parts])
    }
    func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data {
        guard pending.link.server == "controller.invalid", pending.sent else { throw GuestCrypto.Failure.invalidEnvelope }
        redeems += 1
        return Data(#"{"ok":1,"state":"awaiting_owner"}"#.utf8)
    }
    func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite? {
        guard pending.link.server == "controller.invalid" else { throw GuestCrypto.Failure.invalidEnvelope }
        resolves += 1
        guard ready else { return nil }
        let sealed = try BundleKeySeal.seal(Data(repeating: 8, count: 32), recipientPublicKey: pending.recipient.publicKey)
        return try pending.invitation(part: part, keyCipher: sealed)
    }
}


private final class CapturePassServer: DelegationTransport {
    let group = String(repeating: "D", count: 22), code = String(repeating: "C", count: 22)
    var invitations: [[String: Any]] = [], children: [[String: Any]] = []
    var creates = 0, groupsCreated = 0, vouches = 0, revokes = 0
    var loseReply = false
    func delegationInfo(server: String, group: String) async throws -> Data { throw GuestCrypto.Failure.invalidEnvelope }
    func redeemDelegation(_ pending: DelegationRedemption, fingerprint: String) async throws -> Data { throw GuestCrypto.Failure.invalidEnvelope }
    func resolveDelegation(_ pending: DelegationRedemption, part: DelegationRedemption.Part, fingerprint: String) async throws -> GuestInvite? { throw GuestCrypto.Failure.invalidEnvelope }
    func delegate(invite: GuestInvite, fingerprint: String, operation: DelegationOperation, body: Data) async throws -> Data {
        guard invite.server == "controller.invalid" else { throw GuestCrypto.Failure.invalidEnvelope }
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        switch operation {
        case .list:
            return try JSONSerialization.data(withJSONObject: ["objects": [7,8].map { ["id": $0, "depth": 2, "pool_left": 8, "native_only": 0] }, "invites": invitations, "children": children])
        case .create:
            creates += 1
            if json["grp"] == nil { groupsCreated += 1; guard groupsCreated == 1 else { throw GuestCrypto.Failure.invalidEnvelope } }
            else { guard json["grp"] as? String == group else { throw GuestCrypto.Failure.invalidEnvelope } }
            invitations = [["code": code, "grp": group, "status": "new", "objects": json["objects"]!]]
            if loseReply { throw URLError(.networkConnectionLost) }
            return try JSONSerialization.data(withJSONObject: ["code": code, "grp": group])
        case .vouch:
            guard let pub = children[0]["sign_pub"] as? String, let guest = children[0]["guest_pub"] as? String,
                  let signature = json["sig"] as? String,
                  try DelegationProof.verifyVouch(signature, parentPublic: GuestCrypto.signingKey(userKey: invite.userKey).publicKey.rawRepresentation,
                    server: invite.server, childID: 18, signPublic: pub, guestPublic: guest) else { throw GuestCrypto.Failure.invalidKey }
            vouches += 1; children[0]["vouched"] = 1
        case .revoke, .cancel:
            revokes += 1; children = []; invitations[0]["status"] = "cancelled"
        default: throw GuestCrypto.Failure.invalidEnvelope
        }
        return Data(#"{"ok":1}"#.utf8)
    }
}

private final class CaptureMessageAcknowledgements: GuestMessageTransport {
    var delivered = 0, read = 0
    func acknowledgeMessage(invite: GuestInvite, fingerprint: String, kind: MessageAcknowledgement, hash: String) async throws {
        guard invite.server == "controller.invalid", hash.count == 24 else { throw GuestCrypto.Failure.invalidEnvelope }
        if kind == .read { read += 1 } else { delivered += 1 }
    }
}

@MainActor private final class CaptureBLECentral: BLECentralTransport {
    let channel = CaptureBLEChannel()
    let id = UUID()
    var payload: Data?
    func scan(seconds: TimeInterval) async throws -> [BLEDiscovery] {
        [BLEDiscovery(id: id, name: "Entrixy · тестовый контроллер", rssi: -48, manufacturerPayload: payload)]
    }
    func connect(_ discoveryID: UUID, pairing: Bool) async throws -> any BLEChannel {
        guard discoveryID == id else { throw BLETransportFailure.unsupported }
        return channel
    }
    func stop() {}
}
@MainActor private final class CaptureBLEChannel: BLEChannel {
    let pair = BLECrypto.makePair()
    let results: AsyncThrowingStream<UInt8, Error>
    private let output: AsyncThrowingStream<UInt8, Error>.Continuation
    var writes = 0
    var fireWrites = 0
    var timeWrites = 0
    var revokeWrites = 0
    var revokeResult: UInt8 = 0x40
    var nonceReads = 0
    var guestGrant: BLEGuestGrant?
    var lostReply = false
    var lostFireReply = false
    var ownerSecret: Data?
    let nonce = Data([1,2,3,4,5,6,7,8])
    init() {
        var sink: AsyncThrowingStream<UInt8, Error>.Continuation!
        results = AsyncThrowingStream { sink = $0 }; output = sink
    }
    func enableResults() async throws -> Bool { true }
    func read(_ characteristic: String) async throws -> Data {
        if characteristic == BLECrypto.pairPublicCharacteristic { return pair.publicKey }
        nonceReads += 1
        return guestGrant != nil && nonceReads == 1 ? Data([11,12,13,14,15,16,17,18]) : nonce
    }
    func write(_ data: Data, to characteristic: String) async throws {
        if characteristic == BLECrypto.revokeCharacteristic {
            guard let ownerSecret, data.count == 23, data[6] <= 1 else { throw BLETransportFailure.invalidValue }
            let guestID = UInt16(data[0]) | (UInt16(data[1]) << 8)
            let version = data.dropFirst(2).prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
            guard data == (try BLECrypto.revoke(ownerSecret: ownerSecret, guestID: guestID, version: version, revoked: data[6] == 1)) else { throw BLETransportFailure.invalidValue }
            revokeWrites += 1; output.yield(revokeResult)
        } else if characteristic == BLECrypto.timeCharacteristic, let grant = guestGrant {
            guard data.count == 55, timeWrites == 0 else { throw BLETransportFailure.invalidValue }
            let epochMs = data.dropFirst(23).prefix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
            guard data == (try BLECrypto.guestTime(token: grant.token, ownerSignature: grant.ownerSignature, guestKey: grant.guestKey,
                epochMilliseconds: epochMs, nonce: Data([11,12,13,14,15,16,17,18]))) else { throw BLETransportFailure.invalidValue }
            timeWrites += 1; output.yield(0x11)
        } else if characteristic == BLECrypto.fireCharacteristic {
            let expected: Data
            if let grant = guestGrant { expected = try BLECrypto.guestFire(token: grant.token, ownerSignature: grant.ownerSignature, guestKey: grant.guestKey, nonce: nonce) }
            else if let ownerSecret { expected = try BLECrypto.ownerFire(ownerSecret: ownerSecret, nonce: nonce) }
            else { throw BLETransportFailure.invalidValue }
            guard fireWrites == 0, data == expected else { throw BLETransportFailure.invalidValue }
            fireWrites += 1
            if lostFireReply { throw URLError(.networkConnectionLost) }
            output.yield(0x10); output.yield(0)
        } else {
            guard characteristic == BLECrypto.pairDoneCharacteristic, data.count == 36, writes == 0 else { throw BLETransportFailure.invalidValue }
            writes += 1
            if lostReply { throw URLError(.networkConnectionLost) }
        }
    }
    func close() async {}
}

@MainActor
private final class ActionCaptureModel: ObservableObject {
    let model: AppModel
    let scenario: ActionCaptureScenario
    @Published var intent: ActionIntent?
    @Published private(set) var backupManager: BackupManager?
    @Published private(set) var delegationManager: DelegationInbox?
    @Published private(set) var senderManager: PassManager?
    @Published private(set) var bleManager: BLEPairingModel?
    private let bleCentral = CaptureBLECentral()
    @Published private(set) var messageManager: MessageManager?
    private let messageAcknowledgements = CaptureMessageAcknowledgements()
    private let senderServer = CapturePassServer()
    private let delegationServer = CaptureDelegationServer()
    let delegationLink = try! DelegationLink(server: "controller.invalid", group: String(repeating: "A", count: 22), secret: Data(repeating: 5, count: 32))
    @Published private(set) var ready = false
    private let controller = CaptureController()
    private let ownerServer: CaptureOwnerServer
    private var prepared = false
    private var bleRenewLinkPreserved = false

    init(scenario: ActionCaptureScenario) {
        self.scenario = scenario
        let server = CaptureOwnerServer(uncertain: scenario == .ownerUncertain)
        server.loseCreateReply = scenario == .objectUncertain
        server.loseKeyReply = scenario == .issuedUncertain
        server.finishOwnerAction = scenario == .ownerResult || scenario == .ownerJournal
        ownerServer = server
        model = AppModel(storage: KeychainStore(service: "com.entrixy.ios.capture." + UUID().uuidString), ownerAPI: server)
    }
    func prepare() async {
        guard !prepared else { return }; prepared = true
        do {
            if scenario.isDelegation {
                let manager = DelegationInbox(app: model, api: delegationServer, automaticUpdates: false)
                delegationManager = manager
                delegationServer.reject = scenario == .delegationRejected
                delegationServer.ready = scenario == .delegationReady || scenario == .additionalParts
                await manager.inspect(delegationLink.url)
                if scenario == .delegationWaiting || scenario == .delegationReady || scenario == .additionalParts {
                    await manager.accept()
                    if scenario == .delegationWaiting {
                        guard model.delegations.first?.sent == true else { throw GuestCrypto.Failure.invalidEnvelope }
                    }
                    if scenario == .delegationReady { guard model.guests.count == 1 else { throw GuestCrypto.Failure.invalidEnvelope } }
                }
                if scenario == .additionalParts {
                    guard model.guests.count == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                    let original = model.guests[0].invite, recipient = model.receivedDelegations[0].recipient.publicKey
                    delegationServer.extraPart = true
                    await manager.refreshAdditionalParts(); await manager.checkAll()
                    guard model.guests.count == 2, model.guests[0].invite == original,
                          model.receivedDelegations[0].parts.count == 2,
                          model.receivedDelegations[0].recipient.publicKey == recipient else { throw GuestCrypto.Failure.invalidEnvelope }
                }
                guard delegationServer.redeems == (scenario == .additionalParts ? 2 : ([ActionCaptureScenario.delegationWaiting, .delegationReady].contains(scenario) ? 1 : 0)),
                      model.guests.count == (scenario == .additionalParts ? 2 : (scenario == .delegationReady ? 1 : 0)),
                      model.delegations.count == (scenario == .delegationWaiting ? 1 : 0) else { throw GuestCrypto.Failure.invalidEnvelope }
                writeStatus(ready: true); return
            }
            if scenario.isBLEGuest {
                let invite = try GuestInvite.parse("https://controller.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
                let epoch = UInt64(Date().timeIntervalSince1970)
                let expiry = scenario == .bleGuestExpired ? UInt32(epoch - 1) : UInt32(epoch + 3600)
                let secret = Data(repeating: 7, count: 32)
                let token = try BLECrypto.token(guestID: 9, validUntil: expiry)
                let row: [String: Any] = ["id": 7, "did": 123, "label": "Ворота · гостевой Bluetooth", "avatar_type": "preset:3",
                    "token": token.base64EncodedString(), "sig": try BLECrypto.ownerSignature(ownerSecret: secret, token: token).base64EncodedString(),
                    "gkey": try BLECrypto.guestKey(ownerSecret: secret, guestID: 9).base64EncodedString(),
                    "kstate": try BLECrypto.stateKey(ownerSecret: secret).base64EncodedString(), "valid_until": expiry, "tpl": ["confirm_on": true]]
                let bundle = try JSONSerialization.data(withJSONObject: ["ble": [row]])
                let snapshot = Data(#"{"numbers":[{"id":7,"type":"ble"}]}"#.utf8)
                let guest = SavedGuest(invite: invite, objects: try GuestObjects.decode(bundle: bundle, snapshot: snapshot),
                    bleCache: try GuestBLECache(bundle: bundle, snapshot: snapshot, key: invite.bundleKey, epoch: epoch))
                try model.installCaptureGuest(guest)
                bleCentral.payload = Data([123,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0])
                bleCentral.channel.guestGrant = try BLEGuestGrant(row: row)
                bleCentral.channel.lostFireReply = scenario == .bleGuestUnknown
                model.bleGuestControl = BLEGuestControlModel(app: model, transport: bleCentral)
                let action = model.actionIntent(guestID: guest.id, object: guest.objects[0])
                if scenario == .bleGuestExpired {
                    guard action == nil, model.errorMessage != nil, bleCentral.channel.fireWrites == 0 else { throw GuestCrypto.Failure.invalidEnvelope }
                } else {
                    guard let action else { throw GuestCrypto.Failure.invalidEnvelope }
                    if scenario == .bleGuestConfirm { intent = action }
                    else {
                        await model.execute(action)
                        guard bleCentral.channel.fireWrites == 1, bleCentral.channel.timeWrites == 1, model.journal.count == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                    }
                }
                writeStatus(ready: true); return
            }
            if scenario.isOwner {
                if scenario != .ownerForm {
                    let added = await model.addOwner(server: "controller.invalid", accessCode: "")
                    guard added == (scenario != .ownerUncertain), ownerServer.registrations == 1,
                          model.owners.count == 1,
                          model.owners[0].registrationPending == (scenario == .ownerUncertain) else {
                        throw GuestCrypto.Failure.invalidEnvelope
                    }
                    if scenario == .ownerOffline {
                        ownerServer.offline = true
                        await model.refreshOwners()
                        guard model.ownerMessages["controller.invalid"] != nil else { throw GuestCrypto.Failure.invalidEnvelope }
                    }
                    if scenario.isBLEPairing {
                        let manager = BLEPairingModel(app: model, transport: bleCentral)
                        bleManager = manager
                        await manager.scan()
                        if scenario != .bleScan {
                            bleCentral.channel.lostReply = scenario == .bleUncertain
                            await manager.pair(discoveryID: bleCentral.id, server: "controller.invalid", label: "Ворота · Bluetooth")
                            guard let owner = model.owners.first, let record = owner.blePairings?.first,
                                  record.phase == .sent, bleCentral.channel.writes == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                            if scenario != .bleUncertain {
                                let head = Data((0..<4).map { UInt8(truncatingIfNeeded: record.deviceID >> ($0 * 8)) }) + Data([1,0,0,0])
                                let signed = try BLECrypto.ownerFire(ownerSecret: record.secret(masterKey: owner.masterKey), nonce: head)
                                bleCentral.payload = head + signed.dropFirst(8).prefix(8)
                                await manager.check(pairingID: record.id, server: "controller.invalid")
                                guard model.owners.first?.blePairings?.first?.phase == .confirmed else { throw GuestCrypto.Failure.invalidEnvelope }
                                if scenario == .bleRegistered || scenario.isBLEOwner || scenario.isBLELifecycle {
                                    guard await model.registerPairedBLE(server: "controller.invalid", pairingID: record.id) else { throw GuestCrypto.Failure.invalidEnvelope }
                                }
                                if scenario.isBLELifecycle {
                                    bleCentral.channel.ownerSecret = try record.secret(masterKey: owner.masterKey)
                                    model.bleControl = BLEOwnerControlModel(app: model, transport: bleCentral)
                                    guard await model.createOwnerKey(server: "controller.invalid", label: "Bluetooth-гость", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true),
                                          let key = model.owners.first?.issuedKeys?.first else { throw GuestCrypto.Failure.invalidEnvelope }
                                    if scenario == .bleRenewed {
                                        let original = try key.link(server: "controller.invalid", masterKey: owner.masterKey)
                                        await model.renewOwnerBLEKey(server: "controller.invalid", keyID: key.id)
                                        guard let renewed = model.owners.first?.issuedKeys?.first, renewed.pending == nil else { throw GuestCrypto.Failure.invalidEnvelope }
                                        bleRenewLinkPreserved = try renewed.link(server: "controller.invalid", masterKey: owner.masterKey) == original
                                        guard bleRenewLinkPreserved else { throw GuestCrypto.Failure.invalidEnvelope }
                                    } else {
                                        await model.setOwnerKeyMode(server: "controller.invalid", keyID: key.id, paused: true)
                                        guard model.owners.first?.bleRevocations?.count == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                                        if scenario != .bleRevokePending {
                                            bleCentral.channel.revokeResult = scenario == .bleRevokeStale ? 0x41 : 0x40
                                            await model.bleControl.deliverDecisions(server: "controller.invalid", deviceID: record.deviceID)
                                            guard model.owners.first?.bleRevocations?.first?.controllerResult == bleCentral.channel.revokeResult,
                                                  bleCentral.channel.revokeWrites == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                                        }
                                    }
                                }
                                if scenario.isBLEOwner {
                                    bleCentral.channel.ownerSecret = try record.secret(masterKey: owner.masterKey)
                                    bleCentral.channel.lostFireReply = scenario == .bleOwnerUnknown
                                    model.bleControl = BLEOwnerControlModel(app: model, transport: bleCentral)
                                    if scenario != .bleOwnerConfirm {
                                        guard let object = model.owners.first?.objects?.first else { throw GuestCrypto.Failure.invalidEnvelope }
                                        await model.bleControl.execute(server: "controller.invalid", objectID: object.id)
                                        guard bleCentral.channel.fireWrites == 1, model.journal.count == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                                    }
                                }
                            }
                        }
                        guard model.journal.count == (scenario.isBLEOwner && scenario != .bleOwnerConfirm ? 1 : 0) else { throw GuestCrypto.Failure.invalidEnvelope }
                    }
                    if scenario.isObject && scenario != .objectForm {
                        let created = await model.createOwnerObject(server: "controller.invalid", label: "Тестовые ворота", kind: "device", phone: "", url: "", secret: "", claimCode: "TEST1234")
                        guard created == (scenario != .objectUncertain), ownerServer.mutations == 2,
                              let object = model.owners.first?.objects?.first else { throw GuestCrypto.Failure.invalidEnvelope }
                        if scenario == .objectRenamed {
                            let renamed = await model.renameOwnerObject(server: "controller.invalid", objectID: object.id, label: "Ворота во двор")
                            guard renamed else { throw GuestCrypto.Failure.invalidEnvelope }
                        }
                        if scenario == .objectDeleted {
                            await model.deleteOwnerObject(server: "controller.invalid", objectID: object.id)
                            guard model.owners.first?.objects?.isEmpty == true else { throw GuestCrypto.Failure.invalidEnvelope }
                        }
                    }
                    if scenario.isIssuance {
                        let created = await model.createOwnerObject(server: "controller.invalid", label: "Тестовые ворота", kind: "webhook", phone: "", url: "https://actuator.invalid/open", secret: "public-test-only", claimCode: "")
                        guard created else { throw GuestCrypto.Failure.invalidEnvelope }
                        if scenario != .issueForm {
                            let issued = await model.createOwnerKey(server: "controller.invalid", label: "Тестовый гость", numberIDs: [7], welcome: "Доступ к тестовому стенду", nativeOnly: false, confirmation: true, access: scenario == .issuedAccessForm || scenario.isOwnerDelegation ? [7: try KeyObjectAccess(depth: 2, pool: 8)] : nil)
                            guard issued == (scenario != .issuedUncertain),
                                  let key = model.owners.first?.issuedKeys?.first else { throw GuestCrypto.Failure.invalidEnvelope }
                            if scenario == .issuedPaused { await model.setOwnerKeyMode(server: "controller.invalid", keyID: key.id, paused: true) }
                            if scenario == .issuedRevoked { await model.revokeOwnerKey(server: "controller.invalid", keyID: key.id) }
                            if scenario == .issuedEditResult {
                                let edited = await model.editOwnerKey(server: "controller.invalid", keyID: key.id, label: "Обновлённый гость", numberIDs: [7], welcome: "Обновлённое приветствие", confirmation: nil)
                                guard edited else { throw GuestCrypto.Failure.invalidEnvelope }
                            }
                        }
                    }
                    if scenario == .messageCompose || scenario == .messageSent {
                        let manager = MessageManager(app: model, acknowledgements: messageAcknowledgements)
                        messageManager = manager
                        if scenario == .messageSent {
                            let owner = model.owners[0], key = owner.issuedKeys![0]
                            let sent = await manager.send("Тестовое сообщение получателю", target: .owner(server: owner.server, keyID: key.id))
                            guard sent, ownerServer.messagesSent == 1, let cipher = ownerServer.messageCipher,
                                  try GuestMessageCrypto.open(cipher, bundleKey: key.secrets(masterKey: owner.masterKey).bundleKey) == "Тестовое сообщение получателю" else { throw GuestCrypto.Failure.invalidEnvelope }
                        }
                    }
                    if scenario.isOwnerDelegation {
                        let owner = model.owners[0], parent = owner.issuedKeys![0]
                        let pair = try parent.secrets(masterKey: owner.masterKey), recipient = BundleKeySeal.makeRecipient()
                        let pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3").publicKey.rawRepresentation)
                        let signature = try DelegationProof.vouch(userKey: pair.userKey, server: owner.server, childID: 18, signPublic: pub, guestPublic: recipient.publicKey)
                        ownerServer.keyRows.append(["id": 18, "parent_key_id": 17, "enabled": 1, "mode": "auto", "sign_pub": pub,
                            "guest_pub": recipient.publicKey, "vouch_sig": scenario == .delegatedUntrusted ? Data(repeating: 0, count: 64).base64EncodedString() : signature,
                            "number_ids": [7], "ble_ids": [Int](), "objects": [try KeyObjectAccess(depth: 1, pool: 3).json(id: 7)], "needs_bundle": 1])
                        await model.refreshOwners()
                        if scenario != .delegatedUntrusted {
                            guard let key = model.owners[0].delegatedKeys?.first else { throw GuestCrypto.Failure.invalidEnvelope }
                            if scenario != .delegatedAwaiting {
                                ownerServer.loseKeyEditReply = scenario == .delegatedUncertain
                                await model.approveDelegatedKey(server: owner.server, keyID: key.id)
                            }
                            if scenario == .delegatedRevoked { await model.revokeDelegatedKey(server: owner.server, keyID: key.id) }
                        }
                    }
                    if scenario.isOwnerControl {
                        let guestRequest = scenario == .ownerGuestRequest
                        let created = await model.createOwnerObject(server: "controller.invalid", label: "Тестовые ворота", kind: guestRequest ? "call" : "webhook", phone: guestRequest ? "+79990000000" : "", url: guestRequest ? "" : "https://actuator.invalid/open", secret: guestRequest ? "" : "public-test-only", claimCode: "")
                        guard created, let object = model.owners.first?.objects?.first else { throw GuestCrypto.Failure.invalidEnvelope }
                        if guestRequest {
                            let issued = await model.createOwnerKey(server: "controller.invalid", label: "Тестовый гость", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true)
                            guard issued else { throw GuestCrypto.Failure.invalidEnvelope }
                        }
                        model.ownerControl.resume()
                        for _ in 0..<200 {
                            if model.ownerControl.connections["controller.invalid"] == .connected { break }
                            try await Task.sleep(nanoseconds: 10_000_000)
                        }
                        guard model.ownerControl.connections["controller.invalid"] == .connected else { throw GuestCrypto.Failure.invalidEnvelope }
                        if guestRequest {
                            let owner = model.owners[0], key = owner.issuedKeys![0]
                            let pair = try key.secrets(masterKey: owner.masterKey)
                            let frame = try GuestPress.frame(userKey: pair.userKey, host: owner.server, numberID: 7, wireAction: "")
                            let press = (try JSONSerialization.jsonObject(with: frame) as! [String: Any])["press"]!
                            ownerServer.sockets.last?.emit(["type": "do_call", "number_id": 7, "call_id": "capture-guest-call", "user_key_id": 17, "press": press])
                            for _ in 0..<200 {
                                if model.ownerControl.phoneRequests.count == 1 { break }
                                try await Task.sleep(nanoseconds: 10_000_000)
                            }
                            guard model.ownerControl.phoneRequests.count == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                        } else if scenario != .ownerConfirm {
                            await model.ownerControl.execute(server: "controller.invalid", objectID: object.id, action: .open)
                            for _ in 0..<200 {
                                if !ownerServer.finishOwnerAction || model.journal.first?.result == "Тестовый запрос владельца выполнен" { break }
                                try await Task.sleep(nanoseconds: 10_000_000)
                            }
                            guard ownerServer.ownerWrites.count == 1, model.journal.count == 1,
                                  !ownerServer.finishOwnerAction || model.journal.first?.result == "Тестовый запрос владельца выполнен" else { throw GuestCrypto.Failure.invalidEnvelope }
                        }
                    }
                    if scenario.isBackup {
                        let manager = BackupManager(app: model, refreshAfterRestore: false)
                        backupManager = manager
                        if scenario != .backupForm {
                            let bytes = try await manager.export(password: "capture-password")
                            guard bytes.starts(with: Data("ENTRIXY1".utf8)) else { throw GuestCrypto.Failure.invalidEnvelope }
                            if scenario == .backupRejected {
                                do { try await manager.inspect(bytes, password: "incorrect-password"); throw GuestCrypto.Failure.invalidEnvelope }
                                catch BackupEnvelope.Failure.passwordOrDamage { manager.report(BackupEnvelope.Failure.passwordOrDamage) }
                            } else if scenario != .backupExport {
                                try await manager.inspect(bytes, password: "capture-password")
                                if scenario == .backupRestored || scenario == .backupInterrupted {
                                    ownerServer.offline = scenario == .backupInterrupted
                                    await manager.restore()
                                    guard manager.hasPendingRestore == (scenario == .backupInterrupted) else { throw GuestCrypto.Failure.invalidEnvelope }
                                }
                            }
                        }
                    }
                    model.errorMessage = nil // Inline owner status remains visible in the captured screen.
                }
                writeStatus(ready: true)
                return
            }
            // Reserved .invalid domain + public test bytes. This cannot address equipment.
            let invite = try GuestInvite.parse("https://controller.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
            // Add through the isolated storage, never model.add()/refresh() (network).
            let guest = SavedGuest(invite: invite)
            try model.installCaptureGuest(guest)
            let codeScenarios: [ActionCaptureScenario] = [.codeSetup, .codeEntry, .codeRejected, .biometric]
            let codeScenario = codeScenarios.contains(scenario)
            let template: [String: Any] = codeScenario
                ? ["auth_on": true, "auth": scenario == .biometric ? "either" : "pin"]
                : ["confirm_on": true]
            if codeScenario && scenario != .codeSetup { try await model.setActionCode("1234") }
            let key = Data(repeating: 8, count: 32)
            var bundle: [String: Any] = ["obj_keys": ["7": GuestCrypto.base64URL(key)], "templates": ["7": template],
                "sock": ["7": ["guest_id": 513, "token": Data([1, 2, 1]).base64EncodedString(),
                    "sig": Data(repeating: 4, count: 16).base64EncodedString(), "gkey": Data(0..<32).base64EncodedString()]]]
            let metadata: [String: Any] = ["label": "Тестовые ворота", "avatar_type": "preset:3"]
            let cipher = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: metadata))
            var rows: [[String: Any]] = [["id": 7, "type": "device", "device_id": 9, "data_cipher": cipher]]
            if scenario.isSender {
                let secondKey = Data(repeating: 9, count: 32)
                bundle["obj_keys"] = ["7": GuestCrypto.base64URL(key), "8": GuestCrypto.base64URL(secondKey)]
                bundle["templates"] = ["7": template, "8": ["confirm_on": true, "server_webhook": true]]
                let data = try JSONSerialization.data(withJSONObject: ["label": "Тестовая калитка", "avatar_type": "preset:2"])
                rows.append(["id": 8, "type": "webhook", "data_cipher": try GuestCrypto.encrypt(key: secondKey, plaintext: data)])
            }
            let snapshot = try JSONSerialization.data(withJSONObject: ["type": "guest_ok", "mode": "on", "numbers": rows])
            try model.attachTestController(controller, guestID: guest.id, bundle: JSONSerialization.data(withJSONObject: bundle), snapshot: snapshot)
            try await model.receiveTestController(Data(#"{"type":"devices_online","device_ids":[9]}"#.utf8), guestID: guest.id)
            if scenario.isMessageIncoming {
                let manager = MessageManager(app: model, acknowledgements: messageAcknowledgements)
                let message = try GuestMessageCrypto.seal("Тестовое сообщение по ключу. Ворота и калитка доступны в приложении.", bundleKey: scenario == .messageCorrupt ? Data(repeating: 99, count: 32) : invite.bundleKey)
                await manager.receive(message, guestID: guest.id)
                messageManager = manager
                if scenario == .messageRead {
                    // Read acknowledgement comes from the actual read screen's task.
                    for _ in 0..<600 {
                        if model.incomingMessages.first?.readAcknowledged == true { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    guard model.incomingMessages.first?.readAcknowledged == true else { throw GuestCrypto.Failure.invalidEnvelope }
                }
                guard model.incomingMessages.count == (scenario == .messageCorrupt ? 0 : 1) else { throw GuestCrypto.Failure.invalidEnvelope }
                writeStatus(ready: true); return
            }
            if scenario.isSender {
                let manager = PassManager(app: model, api: senderServer)
                senderManager = manager
                senderServer.loseReply = scenario == .senderUncertain
                if scenario == .senderForm { await manager.reload() }
                else {
                    let objects = scenario == .senderEdited ? [7: try KeyObjectAccess(depth: 0, pool: 1), 8: try KeyObjectAccess(depth: 0, pool: 1)] : [7: try KeyObjectAccess(depth: 0, pool: 1)]
                    guard let id = await manager.create(label: "Тестовый получатель", welcome: "Доступ к тестовому стенду", objects: [guest.id: objects]),
                          let record = model.passedAccess.first else { throw GuestCrypto.Failure.invalidEnvelope }
                    if scenario == .senderVouched {
                        let recipient = BundleKeySeal.makeRecipient()
                        let pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3").publicKey.rawRepresentation)
                        senderServer.invitations[0]["status"] = "redeemed"
                        senderServer.children = [["id": 18, "grp": senderServer.group, "number_ids": [7], "ble_ids": [Int](),
                            "objects": [try KeyObjectAccess(depth: 0, pool: 1).json(id: 7)], "sign_pub": pub, "guest_pub": recipient.publicKey,
                            "pass_mac": try DelegationProof.passMAC(secret: record.secret, group: senderServer.group, signPublic: pub, guestPublic: recipient.publicKey), "vouched": 0, "ready": 0]]
                        await manager.reload()
                        guard senderServer.vouches == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                    }
                    if scenario == .senderRevoked { await manager.revoke(id) }
                    if scenario == .senderEdited {
                        let edited = await manager.editObjects(id, sourceID: guest.id, numberIDs: [7])
                        guard edited, model.passedAccess[0].parts[0].pendingEdit == nil else { throw GuestCrypto.Failure.invalidEnvelope }
                    }
                }
                writeStatus(ready: true); return
            }
            if scenario == .confirmClose {
                try await model.receiveTestController(Data(#"{"type":"obj_state_update","num_id":7,"position":"open"}"#.utf8), guestID: guest.id)
            }
            guard let object = model.guests.first?.objects.first,
                  let action = model.actionIntent(guestID: guest.id, object: object) else { throw GuestCrypto.Failure.invalidEnvelope }
            switch scenario {
            case .control, .settings, .guests, .addKey, .keyDetail:
                break
            case .bleRevokePending, .bleRevokeApplied, .bleRevokeStale, .bleRenewed,
                 .bleGuestConfirm, .bleGuestResult, .bleGuestExpired, .bleGuestUnknown, .bleGuestJournal,
                 .bleScan, .bleUncertain, .blePaired, .bleRegistered, .bleOwnerConfirm, .bleOwnerResult, .bleOwnerUnknown, .bleOwnerJournal,
                 .messageInbox, .messageRead, .messageCorrupt, .messageCompose, .messageSent,
                 .senderForm, .senderLink, .senderUncertain, .senderVouched, .senderRevoked, .senderEditForm, .senderEdited,
                 .delegatedAwaiting, .delegatedReady, .delegatedUncertain, .delegatedRevoked, .delegatedUntrusted,
                 .delegationPreview, .delegationWaiting, .delegationReady, .delegationRejected, .additionalParts,
                 .backupForm, .backupExport, .backupPreview, .backupRestored, .backupRejected, .backupInterrupted,
                 .ownerForm, .ownerReady, .ownerUncertain, .ownerOffline,
                 .ownerConfirm, .ownerSending, .ownerResult, .ownerJournal, .ownerGuestRequest,
                 .issueForm, .issuedKey, .issuedList, .issuedPaused, .issuedRevoked, .issuedUncertain, .issuedRevokeConfirm, .issuedEditForm, .issuedEditResult, .issuedAccessForm,
                 .objectForm, .objectCreated, .objectEdit, .objectRenamed, .objectDelete, .objectDeleted, .objectUncertain:
                throw GuestCrypto.Failure.invalidEnvelope
            case .confirmOpen, .confirmClose, .codeSetup, .codeEntry, .codeRejected, .biometric:
                intent = action
            case .offline:
                try await model.receiveTestController(Data(#"{"type":"device_online","device_id":9,"online":false}"#.utf8), guestID: guest.id)
                guard model.actionIntent(guestID: guest.id, object: object) == nil, controller.frames.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
            case .requestSent, .result, .journal:
                await model.execute(action)
                guard controller.frames.count == 1, model.journal.count == 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                if scenario != .requestSent {
                    let challenge: [String: Any] = ["type": "sock_challenge", "number_id": 7, "command_id": "capture-command", "nonce": Data(0..<16).base64EncodedString()]
                    try await model.receiveTestController(JSONSerialization.data(withJSONObject: challenge), guestID: guest.id)
                    guard controller.verifiedFire() else { throw GuestCrypto.Failure.invalidEnvelope }
                    // Actual response of this software controller, explicitly not a hardware result.
                    try await model.receiveTestController(Data(#"{"type":"device_status","number_id":7,"message":"Тестовая команда выполнена","level":"success"}"#.utf8), guestID: guest.id)
                    guard model.journal.first?.result == "Тестовая команда выполнена" else { throw GuestCrypto.Failure.invalidEnvelope }
                }
            }
            writeStatus(ready: true)
        } catch { writeStatus(ready: false) }
    }
    private func writeStatus(ready: Bool) {
        self.ready = ready // Re-render routes that depend on asynchronously prepared keys/objects.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let data: [String: Any] = ["ready": ready, "software_controller": true, "scenario": scenario.rawValue,
            "command_frames": controller.frames.count, "journal_count": model.journal.count,
            "live_connections": model.connections.values.filter { $0 == .connected }.count,
            "registration_requests": ownerServer.registrations, "sync_requests": ownerServer.syncs,
            "owner_count": model.owners.count, "owner_pending": model.owners.first?.registrationPending ?? false,
            "owned_object_count": model.owners.first?.objects?.count ?? 0, "mutation_requests": ownerServer.mutations,
            "object_pending": model.owners.first?.objects?.first?.pending != nil,
            "issued_key_count": model.owners.first?.issuedKeys?.count ?? 0, "key_mutation_requests": ownerServer.keyMutations,
            "issued_key_pending": model.owners.first?.issuedKeys?.first?.pending != nil,
            "issued_key_state": model.owners.first?.issuedKeys?.first?.state.rawValue ?? "none",
            "ble_pair_count": model.owners.first?.blePairings?.count ?? 0,
            "ble_pair_state": model.owners.first?.blePairings?.first?.phase.rawValue ?? "none",
            "ble_pair_writes": bleCentral.channel.writes, "ble_fire_writes": bleCentral.channel.fireWrites, "ble_time_writes": bleCentral.channel.timeWrites,
            "ble_revoke_writes": bleCentral.channel.revokeWrites,
            "ble_revoke_count": model.owners.first?.bleRevocations?.count ?? 0,
            "ble_revoke_result": Int(model.owners.first?.bleRevocations?.first?.controllerResult ?? 255),
            "ble_renew_link_preserved": bleRenewLinkPreserved,
            "incoming_message_count": model.incomingMessages.count, "outgoing_message_count": model.outgoingMessages.count,
            "message_delivered_acks": messageAcknowledgements.delivered, "message_read_acks": messageAcknowledgements.read,
            "message_posts": ownerServer.messagesSent,
            "sender_count": model.passedAccess.count, "sender_groups": senderServer.groupsCreated,
            "sender_vouches": senderServer.vouches, "sender_revokes": senderServer.revokes,
            "sender_state": model.passedAccess.first?.parts.first?.state.rawValue ?? "none",
            "sender_object_count": model.passedAccess.first?.parts.first?.objects.count ?? 0,
            "owner_delegated_count": model.owners.first?.delegatedKeys?.count ?? 0,
            "owner_delegated_state": model.owners.first?.delegatedKeys?.first?.state.rawValue ?? "none",
            "owner_delegated_sent": model.owners.first?.delegatedKeys?.first?.sent ?? false,
            "owner_delegation_unverified": model.unverifiedOwnerDelegations["controller.invalid"] ?? 0,
            "delegation_redeems": delegationServer.redeems, "delegation_resolves": delegationServer.resolves,
            "delegation_pending": model.delegations.count, "received_key_count": model.guests.count,
            "backup_encrypted": backupManager?.exportData != nil,
            "backup_preview": backupManager?.preview != nil,
            "backup_pending": model.backupPlan() != nil,
            "backup_message": backupManager?.message != nil,
            "owner_command_frames": ownerServer.ownerWrites.count, "owner_phone_requests": model.ownerControl.phoneRequests.count]
        try? JSONSerialization.data(withJSONObject: data).write(to: cache.appendingPathComponent("action-capture-status.json"), options: .atomic)
    }
}

struct CaptureEnvironmentBadge: View {
    var body: some View {
        Text("ТЕСТОВЫЙ СТЕНД · БЕЗ ОБОРУДОВАНИЯ")
            .font(.caption2.weight(.semibold)).foregroundStyle(Brand.ink)
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .allowsHitTesting(false)
    }
}

@MainActor
struct ActionCaptureRoot: View {
    @StateObject private var capture: ActionCaptureModel
    @State private var taskSheetPresented = false
    init(scenario: ActionCaptureScenario) { _capture = StateObject(wrappedValue: ActionCaptureModel(scenario: scenario)) }
    @ViewBuilder private var content: some View {
        switch capture.scenario {
        case .bleScan, .bleUncertain, .blePaired:
            if let manager = capture.bleManager { NavigationStack { BLEPairingScreen(server: "controller.invalid", manager: manager) } } else { ProgressView() }
        case .bleRevokePending, .bleRevokeApplied, .bleRevokeStale:
            if let record = capture.model.owners.first?.blePairings?.first { NavigationStack { BLEPermissionsScreen(server: "controller.invalid", deviceID: record.deviceID) } } else { ProgressView() }
        case .bleRenewed:
            if let key = capture.model.owners.first?.issuedKeys?.first { NavigationStack { OwnerKeyScreen(server: "controller.invalid", keyID: key.id) } } else { ProgressView() }
        case .bleGuestConfirm, .bleGuestResult, .bleGuestExpired, .bleGuestUnknown: RootView(initialTab: .control)
        case .bleGuestJournal: RootView(initialTab: .journal)
        case .bleOwnerConfirm, .bleOwnerResult, .bleOwnerUnknown: RootView(initialTab: .control)
        case .bleOwnerJournal: RootView(initialTab: .journal)
        case .bleRegistered: NavigationStack { OwnerObjectsScreen(server: "controller.invalid") }
        case .messageInbox, .messageCorrupt, .messageSent:
            if let manager = capture.messageManager { NavigationStack { MessagesScreen(manager: manager) } } else { ProgressView() }
        case .messageRead:
            if let manager = capture.messageManager, let saved = capture.model.incomingMessages.first { NavigationStack { ReadMessageScreen(manager: manager, messageID: saved.id) } } else { ProgressView() }
        case .messageCompose:
            if let manager = capture.messageManager, let key = capture.model.owners.first?.issuedKeys?.first { ComposeMessageScreen(manager: manager, target: .owner(server: "controller.invalid", keyID: key.id)) } else { ProgressView() }
        case .senderForm:
            if let manager = capture.senderManager { PassAccessForm(manager: manager) } else { ProgressView() }
        case .senderEditForm:
            if let manager = capture.senderManager, let record = capture.model.passedAccess.first { EditPassedObjects(manager: manager, accessID: record.id, sourceID: record.parts[0].sourceID) } else { ProgressView() }
        case .senderLink, .senderUncertain, .senderVouched, .senderRevoked, .senderEdited:
            if let manager = capture.senderManager, let record = capture.model.passedAccess.first { NavigationStack { PassedAccessDetail(manager: manager, accessID: record.id) } } else { ProgressView() }
        case .delegatedUntrusted: RootView(initialTab: .guests)
        case .delegatedAwaiting, .delegatedReady, .delegatedUncertain, .delegatedRevoked:
            if let key = capture.model.owners.first?.delegatedKeys?.first { NavigationStack { OwnerDelegatedKeyScreen(server: "controller.invalid", keyID: key.id) } }
            else { ProgressView() }
        case .delegationPreview, .delegationRejected:
            if let manager = capture.delegationManager { KeyImportScreen(input: .constant(capture.delegationLink.url), delegationManager: manager) }
            else { ProgressView() }
        case .delegationWaiting, .delegationReady, .additionalParts:
            if let manager = capture.delegationManager { NavigationStack { DelegationInboxScreen(manager: manager) } }
            else { ProgressView() }
        case .backupForm, .backupExport, .backupPreview, .backupRestored, .backupRejected, .backupInterrupted:
            if let manager = capture.backupManager { NavigationStack { BackupScreen(manager: manager) } }
            else { ProgressView() }
        case .ownerConfirm, .ownerSending, .ownerResult, .ownerGuestRequest: RootView(initialTab: .control)
        case .ownerJournal: RootView(initialTab: .journal)
        case .issueForm: IssueOwnerKeyScreen()
        case .issuedList: RootView(initialTab: .guests)
        case .issuedEditForm, .issuedAccessForm:
            if let key = capture.model.owners.first?.issuedKeys?.first { IssueOwnerKeyScreen(serverPreset: "controller.invalid", editingKeyID: key.id, editAccessOnLaunch: capture.scenario == .issuedAccessForm) }
            else { ProgressView() }
        case .issuedKey, .issuedPaused, .issuedRevoked, .issuedUncertain, .issuedRevokeConfirm, .issuedEditResult:
            if let key = capture.model.owners.first?.issuedKeys?.first {
                NavigationStack { OwnerKeyScreen(server: "controller.invalid", keyID: key.id, showRevokeOnLaunch: capture.scenario == .issuedRevokeConfirm) }
            } else { ProgressView() }
        case .objectForm: AddOwnerObjectScreen(server: "controller.invalid")
        case .objectCreated, .objectRenamed, .objectDeleted, .objectUncertain:
            NavigationStack { OwnerObjectsScreen(server: "controller.invalid") }
        case .objectEdit, .objectDelete:
            if let object = capture.model.owners.first?.objects?.first {
                NavigationStack { OwnerObjectEditor(server: "controller.invalid", objectID: object.id, showDeleteOnLaunch: capture.scenario == .objectDelete) }
            } else { ProgressView() }
        case .ownerForm: AddOwnerServerScreen(initialServer: "controller.invalid")
        case .ownerReady, .ownerUncertain, .ownerOffline: NavigationStack { OwnerServersScreen() }
        case .keyDetail:
            if let guest = capture.model.guests.first { NavigationStack { KeyDetailScreen(guestID: guest.id) } }
            else { ProgressView() }
        default:
            RootView(initialTab: capture.scenario == .journal ? .journal
                     : (capture.scenario == .settings ? .settings : (capture.scenario == .guests ? .guests : .control)),
                     showAddKey: capture.scenario == .addKey)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Group {
            if capture.scenario.presentsPreparedTaskSheet {
                RootView(initialTab: capture.scenario.taskBackgroundTab)
                    .sheet(isPresented: $taskSheetPresented) {
                        content.environmentObject(capture.model)
                    }
            } else {
                content
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            if !capture.scenario.usesTaskFooter && capture.intent == nil { CaptureEnvironmentBadge() }
        }
        .environmentObject(capture.model)
        .sheet(item: $capture.intent) { intent in
            ActionConfirmation(intent: intent).environmentObject(capture.model)
        }
        .task {
            await capture.prepare()
            if capture.ready && capture.scenario.presentsPreparedTaskSheet { taskSheetPresented = true }
        }
    }
}
#endif
