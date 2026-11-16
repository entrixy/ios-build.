import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct OwnerIssuedKey: Codable, Identifiable, Equatable {
    public enum State: String, Codable { case draft, active, paused, revoked, unavailable, restricted }
    public let id: UUID
    public var label: String
    public var numberIDs: [Int]
    public let guestID: Int
    public let nativeOnly: Bool
    public let wrappedSecrets: String
    public var bundleCipher: String
    public var keyID: Int?
    public var effectiveNumberIDs: [Int]?
    public var state: State
    public var pending: OwnerOperation?
    public var pendingMode: String?
    /// Authority chosen locally; server snapshots may restrict it but cannot enlarge it.
    public var grantedAccess: [String: KeyObjectAccess]?
    public var access: [String: KeyObjectAccess]?
    public var requestedAccess: [String: KeyObjectAccess]?
    public var accessNeedsReview: Bool?
    public var automationTemplates: [String: Data]?
    public var streamAllowed: [Int]?
    public var objectSettingsToken: String?
    public var sent: Bool

    public init(owner: OwnerAccount, label: String, numberIDs: [Int], welcome: String, nativeOnly: Bool, confirmation: Bool, access: [Int: KeyObjectAccess]? = nil) throws {
        guard !nativeOnly else { throw GuestCrypto.Failure.invalidKey }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
        var used = Set((owner.issuedKeys ?? []).map(\.guestID))
        used.formUnion((owner.delegatedKeys ?? []).map(\.guestID))
        used.formUnion((owner.bleRevocations ?? []).map { Int($0.guestID) })
        used.formUnion(owner.reservedGuestIDs ?? [])
        used.formUnion((owner.androidKeys ?? []).compactMap(\.guestID))
        guard used.count < 65535 else { throw GuestCrypto.Failure.invalidKey }
        var did: Int
        repeat { did = Int.random(in: 1...65535) } while used.contains(did)
        let userKey = GuestCrypto.base64URL(GuestCrypto.randomBytes(count: 24))
        let bundleKey = GuestCrypto.randomBytes(count: 32)
        let bundle = try Self.makeBundle(owner: owner, numberIDs: numberIDs, guestID: did, welcome: welcome, confirmation: confirmation)
        id = UUID(); self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.numberIDs = numberIDs.sorted(); guestID = did; self.nativeOnly = nativeOnly
        wrappedSecrets = try GuestCrypto.encrypt(key: owner.masterKey, plaintext: JSONSerialization.data(withJSONObject: ["user_key": userKey, "bundle_key": GuestCrypto.base64URL(bundleKey)], options: .sortedKeys))
        bundleCipher = try GuestCrypto.encrypt(key: bundleKey, plaintext: bundle)
        grantedAccess = try Self.checkedAccess(access ?? Dictionary(uniqueKeysWithValues: numberIDs.map { ($0, try! KeyObjectAccess()) }), numberIDs: numberIDs)
        if let access { requestedAccess = try Self.checkedAccess(access, numberIDs: numberIDs) }
        state = .draft; pending = .keyCreate; sent = false
    }

    public func bundle(masterKey: Data) throws -> [String: Any] {
        let pair = try secrets(masterKey: masterKey)
        guard let bundle = try JSONSerialization.jsonObject(with: GuestCrypto.decrypt(key: pair.bundleKey, envelope: bundleCipher)) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        return bundle
    }

    public mutating func edit(owner: OwnerAccount, label: String, numberIDs: [Int], welcome: String, confirmation: Bool? = nil, access: [Int: KeyObjectAccess]? = nil) throws {
        guard pending == nil, keyID != nil, state == .active || state == .paused, !nativeOnly,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 512 else { throw GuestCrypto.Failure.invalidEnvelope }
        let pair = try secrets(masterKey: owner.masterKey)
        let existing = try bundle(masterKey: owner.masterKey)
        let chosenTemplates = automationTemplates?.filter { numberIDs.contains(Int($0.key) ?? -1) }
        let chosenStreams = streamAllowed?.filter { numberIDs.contains($0) }
        let bytes = try Self.makeBundle(owner: owner, numberIDs: numberIDs, guestID: guestID, welcome: welcome, confirmation: confirmation, existing: existing,
            automation: chosenTemplates, streamAllowed: chosenStreams)
        let cipher = try GuestCrypto.encrypt(key: pair.bundleKey, plaintext: bytes)
        if let access { requestedAccess = try Self.checkedAccess(access, numberIDs: numberIDs) }
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.numberIDs = numberIDs.sorted()
        bundleCipher = cipher
        automationTemplates = chosenTemplates; streamAllowed = chosenStreams
        pending = .keyEdit; sent = false
    }

    public mutating func renewBLE(owner: OwnerAccount) throws {
        guard state == .active, pending == nil, keyID != nil else { throw GuestCrypto.Failure.invalidEnvelope }
        let existing = try bundle(masterKey: owner.masterKey)
        guard let rows = existing["ble"] as? [[String: Any]], !rows.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        let pair = try secrets(masterKey: owner.masterKey)
        let bytes = try Self.makeBundle(owner: owner, numberIDs: numberIDs, guestID: guestID,
            welcome: existing["welcome"] as? String ?? "", confirmation: nil, existing: existing, renewBLE: true,
            automation: automationTemplates, streamAllowed: streamAllowed)
        bundleCipher = try GuestCrypto.encrypt(key: pair.bundleKey, plaintext: bytes)
        pending = .keyEdit; sent = false
    }

    private static func checkedAccess(_ access: [Int: KeyObjectAccess], numberIDs: [Int]) throws -> [String: KeyObjectAccess] {
        guard Set(access.keys) == Set(numberIDs), access.values.allSatisfy({ !$0.nativeOnly }) else { throw GuestCrypto.Failure.invalidEnvelope }
        for value in access.values { try value.validate() }
        return Dictionary(uniqueKeysWithValues: access.map { (String($0.key), $0.value) })
    }

    static func makeBundle(owner: OwnerAccount, numberIDs: [Int], guestID: Int, welcome: String, confirmation: Bool?, existing: [String: Any] = [:], renewBLE: Bool = false,
                           automation: [String: Data]? = nil, streamAllowed: [Int]? = nil, inheritRestrictions: Bool = false) throws -> Data {
        guard !numberIDs.isEmpty, Set(numberIDs).count == numberIDs.count, welcome.utf8.count <= 4096 else { throw GuestCrypto.Failure.invalidEnvelope }
        let selected = (owner.objects ?? []).filter { numberIDs.contains($0.numberID ?? -1) }
        guard selected.count == numberIDs.count, selected.allSatisfy({ $0.pending == nil && $0.available != false }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let oldBLE = existing["ble"] as? [[String: Any]] ?? []
        guard existing["ble"] == nil || existing["ble"] is [[String: Any]] else { throw GuestCrypto.Failure.invalidEnvelope }
        let oldBLEIDs = try oldBLE.map { try OwnerObject.replyID($0["id"]) }
        guard Set(oldBLEIDs).count == oldBLEIDs.count else { throw GuestCrypto.Failure.invalidEnvelope }
        var ble: [[String: Any]] = []
        let oldTemplates = existing["templates"] as? [String: [String: Any]] ?? [:]
        if existing["templates"] != nil && existing["templates"] as? [String: [String: Any]] == nil { throw GuestCrypto.Failure.invalidEnvelope }
        let oldEpochs = existing["obj_epoch"] as? [String: Int] ?? [:]
        let oldPrevious = existing["obj_keys_prev"] as? [String: String] ?? [:]
        var keys: [String: String] = [:], previous: [String: String] = [:], epochs: [String: Int] = [:]
        var templates: [String: [String: Any]] = [:], sockets: [String: [String: Any]] = [:]
        func objectTemplate(_ object: OwnerObject, fallback: [String: Any]) throws -> [String: Any] {
            guard let id = object.numberID else { throw GuestCrypto.Failure.invalidEnvelope }
            var json = fallback
            if let data = automation?[String(id)] {
                let raw = try AutomationTemplate(data: data)
                let resolved = raw.resolvingGeo(from: try AutomationTemplate(data: object.localPolicy))
                guard let decoded = try JSONSerialization.jsonObject(with: resolved.data()) as? [String: Any] else { throw GuestCrypto.Failure.invalidEnvelope }
                json = decoded
            }
            if object.kind == "ble" {
                let own = try AutomationTemplate(data: object.localPolicy)
                let maximum = own.bleEnabled ? max(1, own.bleRadiusM) : 30
                json["ble_rad_o"] = inheritRestrictions ? min(fallback["ble_rad_o"] as? Int ?? maximum, maximum) : maximum
            }
            return json
        }
        for object in selected {
            guard let number = object.numberID else { throw GuestCrypto.Failure.invalidEnvelope }
            let id = String(number), metadata = try object.metadata(masterKey: owner.masterKey)
            if object.kind == "ble" {
                let old = oldBLE.first { ($0["id"] as? Int) == number }
                var template = try objectTemplate(object, fallback: old?["tpl"] as? [String: Any] ?? oldTemplates[String(number)] ?? ["mode": "any", "confirm_on": true])
                if old?["tpl"] != nil && old?["tpl"] as? [String: Any] == nil { throw GuestCrypto.Failure.invalidEnvelope }
                if let confirmation { template["confirm_on"] = confirmation; template.removeValue(forKey: "confirm") }
                ble.append(try BLEBundle.row(object: object, masterKey: owner.masterKey, guestID: guestID,
                    template: template, existing: old, renew: renewBLE))
                continue
            }
            guard ["phone", "webhook_url", "webhook_secret"].allSatisfy({ metadata[$0] == nil || metadata[$0] is NSNull }) else { throw GuestCrypto.Failure.invalidEnvelope }
            keys[id] = GuestCrypto.base64URL(try GuestCrypto.decrypt(key: owner.masterKey, envelope: object.wrappedKey))
            epochs[id] = oldEpochs[id] ?? 1
            if let old = oldPrevious[id] {
                guard try GuestCrypto.decodeBase64URL(old).count == 32 else { throw GuestCrypto.Failure.invalidKey }
                previous[id] = old
            }
            var template = try objectTemplate(object, fallback: oldTemplates[id] ?? ["mode": "any", "confirm_on": true])
            if let confirmation { template["confirm_on"] = confirmation; template.removeValue(forKey: "confirm") }
            template["server_webhook"] = object.kind == "webhook" && object.routing["webhook_mode"] == "server"
            templates[id] = template
            if object.kind == "device" {
                guard let wrapped = object.wrappedSocketSecret else { throw GuestCrypto.Failure.invalidKey }
                sockets[id] = try socketGrant(ownerSecret: GuestCrypto.decrypt(key: owner.masterKey, envelope: wrapped), guestID: guestID)
            }
        }
        var bundle = existing
        bundle["obj_ids"] = selected.filter { $0.kind != "ble" }.compactMap(\.numberID).sorted(); bundle["ble"] = ble; bundle["obj_keys"] = keys; bundle["obj_keys_prev"] = previous; bundle["obj_epoch"] = epochs
        bundle["templates"] = templates; bundle["sock"] = sockets; bundle["welcome"] = welcome
        if bundle["host_label"] == nil { bundle["host_label"] = "" }
        if bundle["net_block"] == nil { bundle["net_block"] = [String]() }
        let oldStreams = existing["streams"] as? [Int]
        if existing["streams"] != nil && oldStreams == nil { throw GuestCrypto.Failure.invalidEnvelope }
        if let streamAllowed { guard Set(streamAllowed).isSubset(of: Set(numberIDs)) else { throw GuestCrypto.Failure.invalidEnvelope } }
        let defaultStreams = inheritRestrictions ? [] : selected.filter { $0.kind != "ble" }.compactMap(\.numberID)
        let allowedStreams = Set((streamAllowed ?? oldStreams ?? defaultStreams).filter { numberIDs.contains($0) })
        let oldCameras = existing["cams"] as? [String: Any] ?? [:]
        if existing["cams"] != nil && existing["cams"] as? [String: Any] == nil { throw GuestCrypto.Failure.invalidEnvelope }
        var cameras: [String: Any] = [:]
        for object in selected where object.kind != "ble" {
            guard let id = object.numberID, allowedStreams.contains(id) else { continue }
            if let camera = object.localConfiguration?.camera {
                if !camera.url.isEmpty { cameras[String(id)] = try camera.wire() }
            } else if let old = oldCameras[String(id)] { cameras[String(id)] = old }
        }
        bundle["streams"] = allowedStreams.sorted(); bundle["cams"] = cameras
        return try JSONSerialization.data(withJSONObject: bundle, options: .sortedKeys)
    }

    public func secrets(masterKey: Data) throws -> (userKey: String, bundleKey: Data) {
        let clear = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedSecrets)
        guard let json = try JSONSerialization.jsonObject(with: clear) as? [String: String],
              let user = json["user_key"], user.count == 32, let encoded = json["bundle_key"] else { throw GuestCrypto.Failure.invalidKey }
        let key = try GuestCrypto.decodeBase64URL(encoded)
        guard key.count == 32, try GuestCrypto.decodeBase64URL(user).count == 24 else { throw GuestCrypto.Failure.invalidKey }
        return (user, key)
    }

    public func validate(masterKey: Data) throws {
        guard (1...65535).contains(guestID), !numberIDs.isEmpty, numberIDs.allSatisfy({ $0 > 0 }),
              Set(numberIDs).count == numberIDs.count,
              pending == .keyEdit || effectiveNumberIDs == nil || Set(effectiveNumberIDs!).isSubset(of: Set(numberIDs)),
              keyID == nil || keyID! > 0,
              keyID != nil || state == .draft,
              pending == nil || [.keyCreate, .keyEdit, .keyMode, .keyRevoke].contains(pending!) else { throw GuestCrypto.Failure.invalidEnvelope }
        for map in [access, requestedAccess, grantedAccess].compactMap({ $0 }) {
            guard Set(map.keys).isSubset(of: Set(numberIDs.map(String.init))) || pending == .keyEdit else { throw GuestCrypto.Failure.invalidEnvelope }
            for item in map.values { try item.validate() }
        }
        guard (automationTemplates ?? [:]).count <= 1000,
              Set((automationTemplates ?? [:]).keys).isSubset(of: Set(numberIDs.map(String.init))),
              Set(streamAllowed ?? []).isSubset(of: Set(numberIDs)),
              Set(streamAllowed ?? []).count == (streamAllowed ?? []).count else { throw GuestCrypto.Failure.invalidEnvelope }
        if let objectSettingsToken { guard UUID(uuidString: objectSettingsToken) != nil else { throw GuestCrypto.Failure.invalidEnvelope } }
        for data in (automationTemplates ?? [:]).values { _ = try AutomationTemplate(data: data) }
        let keys = try secrets(masterKey: masterKey)
        _ = try GuestCrypto.decrypt(key: keys.bundleKey, envelope: bundleCipher)
    }

    public func request(masterKey: Data) throws -> Data {
        guard let pending else { throw GuestCrypto.Failure.invalidEnvelope }
        var body: [String: Any] = [:]
        switch pending {
        case .keyCreate:
            let secrets = try secrets(masterKey: masterKey)
            body = ["key_hash": GuestCrypto.hash(Data(secrets.userKey.utf8)),
                    "sign_pub": GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: secrets.userKey).publicKey.rawRepresentation), "suite": "v1",
                    "number_ids": numberIDs, "ble_ids": [Int](), "bundle_cipher": bundleCipher,
                    "native_only": nativeOnly, "delegate_depth": requestedAccess?.values.map(\.depth).max() ?? 0, "force_when_busy": false,
                    "objects": try numberIDs.map { try (requestedAccess?[String($0)] ?? KeyObjectAccess()).json(id: $0) }]
        case .keyEdit:
            guard let keyID else { throw GuestCrypto.Failure.invalidEnvelope }
            // Omit unchanged settings: the API preserves them.
            body = ["id": keyID, "number_ids": numberIDs, "ble_ids": [Int](), "bundle_cipher": bundleCipher]
            if let requestedAccess { body["objects"] = numberIDs.compactMap { requestedAccess[String($0)]?.json(id: $0) } }
        case .keyMode:
            guard let keyID, let pendingMode, ["off", "auto"].contains(pendingMode) else { throw GuestCrypto.Failure.invalidEnvelope }
            body = ["id": keyID, "mode": pendingMode]
        case .keyRevoke:
            guard let keyID else { throw GuestCrypto.Failure.invalidEnvelope }
            body = ["id": keyID]
        default: throw GuestCrypto.Failure.invalidEnvelope
        }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    public func link(server: String, masterKey: Data) throws -> URL {
        guard state == .active, pending == nil, keyID != nil, !nativeOnly else { throw GuestCrypto.Failure.invalidKey }
        let pair = try secrets(masterKey: masterKey)
        guard let url = URL(string: "https://\(try GuestInvite.normalizeServer(server))/key#\(pair.userKey)\(GuestCrypto.base64URL(pair.bundleKey))") else { throw GuestCrypto.Failure.invalidEnvelope }
        return url
    }

    public static func socketGrant(ownerSecret: Data, guestID: Int) throws -> [String: Any] {
        guard ownerSecret.count == 32, (1...65535).contains(guestID) else { throw GuestCrypto.Failure.invalidKey }
        let token = Data([UInt8(guestID & 255), UInt8(guestID >> 8), 1])
        let signature = Data(HMAC<SHA256>.authenticationCode(for: token, using: SymmetricKey(data: ownerSecret)).prefix(16))
        let info = Data("guest".utf8) + Data(token.prefix(2))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ownerSecret), salt: Data(count: 32), info: info, outputByteCount: 32)
        let bytes = key.withUnsafeBytes { Data($0) }
        return ["guest_id": guestID, "token": token.base64EncodedString(), "sig": signature.base64EncodedString(), "gkey": bytes.base64EncodedString()]
    }
}

public extension OwnerAccount {
    mutating func reconcileIssuedKeys(_ snapshot: OwnerSnapshot) throws {
        var updated: [OwnerIssuedKey] = []
        for var key in issuedKeys ?? [] {
            if key.state == .revoked { updated.append(key); continue }
            if key.pending == .keyCreate && key.sent {
                let matches = snapshot.keyRows.filter { ($0["bundle_cipher"] as? String) == key.bundleCipher }
                guard matches.count <= 1 else { throw GuestCrypto.Failure.invalidEnvelope }
                if let row = matches.first {
                    let id = try OwnerObject.replyID(row["id"])
                    let pair = try key.secrets(masterKey: masterKey)
                    let publicKey = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: pair.userKey).publicKey.rawRepresentation)
                    let confirmedAccess = try KeyObjectAccess.decode(row["objects"])
                    guard key.keyID == nil || key.keyID == id,
                          row["sign_pub"] as? String == publicKey,
                          Set(try Self.allowedIDs(row)) == Set(key.numberIDs),
                          key.requestedAccess == nil || confirmedAccess == key.requestedAccess else { throw GuestCrypto.Failure.invalidEnvelope }
                    key.keyID = id; key.pending = nil; key.sent = false; key.requestedAccess = nil
                }
            }
            if let id = key.keyID {
                if let row = snapshot.keyRows.first(where: { ($0["id"] as? Int) == id }) {
                    let allowed = try Self.allowedIDs(row)
                    let access = try KeyObjectAccess.decode(row["objects"])
                    if key.pending == .keyEdit && key.sent && row["bundle_cipher"] as? String == key.bundleCipher
                        && Set(allowed) == Set(key.numberIDs)
                        && (key.requestedAccess == nil || key.requestedAccess == access) {
                            if let chosen = key.requestedAccess { key.grantedAccess = chosen; key.accessNeedsReview = false }
                            else { key.grantedAccess = key.grantedAccess?.filter { key.numberIDs.contains(Int($0.key) ?? -1) } }
                            key.pending = nil; key.sent = false; key.requestedAccess = nil
                        }
                    let enabled = Self.enabled(row["enabled"])
                    guard let enabled, let mode = row["mode"] as? String, ["off", "auto", "notify", "confirm"].contains(mode) else { throw GuestCrypto.Failure.invalidEnvelope }
                    if key.pending == .keyRevoke && key.sent && !enabled { key.pending = nil; key.sent = false }
                    if key.pending == .keyMode && key.sent && mode == key.pendingMode { key.pending = nil; key.sent = false; key.pendingMode = nil }
                    guard key.pending == .keyEdit || Set(allowed).isSubset(of: Set(key.numberIDs)) else { throw GuestCrypto.Failure.invalidEnvelope }
                    if let access {
                        guard Set(access.keys) == Set(allowed.map(String.init)) else { throw GuestCrypto.Failure.invalidEnvelope }
                        key.access = access
                    }
                    key.effectiveNumberIDs = allowed
                    key.state = !enabled ? .revoked : (allowed.isEmpty ? .unavailable : (mode == "off" ? .paused : (mode == "auto" ? .active : .restricted)))
                } else { key.state = key.pending == .keyRevoke && key.sent ? .revoked : .unavailable }
                if key.state == .revoked { key.pending = nil; key.sent = false; key.pendingMode = nil }
            }
            updated.append(key)
        }
        issuedKeys = updated
    }
    private static func allowedIDs(_ row: [String: Any]) throws -> [Int] {
        guard let raw = row["number_ids"] as? [Any] else { throw GuestCrypto.Failure.invalidEnvelope }
        let ids = try (raw + (row["ble_ids"] as? [Any] ?? [])).map { try OwnerObject.replyID($0) }
        guard Set(ids).count == ids.count else { throw GuestCrypto.Failure.invalidEnvelope }
        return ids
    }
    private static func enabled(_ value: Any?) -> Bool? {
        if let n = value as? NSNumber, n == 0 || n == 1 { return n.boolValue }
        if let string = value as? String, string == "0" || string == "1" { return string == "1" }
        return nil
    }
}
