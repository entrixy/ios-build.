import Foundation

/// Owner-private camera settings. These travel only in an explicitly permitted
/// guest's bundle.cams, never in the object cipher shared with every guest.
public struct ObjectCameraConfiguration: Codable, Equatable {
    public var enabled = false
    public var url = ""
    public var authType = "none"
    public var authValue = ""
    public var authHeader = ""
    public var intervalSec = 5
    public var showWhen = "call"
    public var contentType = "jpeg"
    public init() {}

    public init(wire: [String: Any]) throws {
        self.init()
        guard let on = wire["on"] as? NSNumber, on == 0 || on == 1,
              let url = wire["url"] as? String else { throw GuestCrypto.Failure.invalidEnvelope }
        enabled = on.boolValue; self.url = url
        authType = wire["auth"] as? String ?? "none"; authValue = wire["val"] as? String ?? ""
        authHeader = wire["hdr"] as? String ?? ""; intervalSec = wire["int"] as? Int ?? 5
        showWhen = wire["when"] as? String ?? "call"; contentType = wire["ct"] as? String ?? "jpeg"
        try validate()
    }

    public func wire() throws -> [String: Any] {
        try validate()
        return ["on": enabled ? 1 : 0, "url": url, "auth": authType, "val": authValue,
                "hdr": authHeader, "int": intervalSec, "when": showWhen, "ct": contentType]
    }

    public func validate() throws {
        guard ["none", "basic", "bearer", "header"].contains(authType),
              ["always", "call", "nearby"].contains(showWhen),
              ["jpeg", "mjpeg"].contains(contentType), (0...30).contains(intervalSec),
              url.utf8.count <= 8192, authValue.utf8.count <= 8192,
              authHeader.utf8.count <= 256,
              !authValue.contains("\r"), !authValue.contains("\n") else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        if enabled {
            // Validate placeholders without changing the stored Android format.
            let sample = url.replacingOccurrences(of: "{token}", with: "token")
                .replacingOccurrences(of: "{ts}", with: "1").replacingOccurrences(of: "{key_id}", with: "1")
            guard let parsed = URLComponents(string: sample), let host = parsed.host, !host.isEmpty,
                  ["https", "http", "rtsp", "rtmp"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.fragment == nil else { throw GuestCrypto.Failure.invalidEnvelope }
            if authType == "header" {
                let permitted = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                guard !authHeader.isEmpty, authHeader.allSatisfy({ permitted.contains($0) }) else {
                    throw GuestCrypto.Failure.invalidEnvelope
                }
            }
        }
    }
}

public struct OwnerObjectLocalConfiguration: Codable, Equatable {
    public var hangupSeconds = 0
    public var camera = ObjectCameraConfiguration()
    public init() {}
    public func validate() throws {
        guard (0...30).contains(hangupSeconds) else { throw GuestCrypto.Failure.invalidEnvelope }
        try camera.validate()
    }
}

/// A draft contains the complete Android edit form and the version it was
/// opened against. Dismissing it never mutates stored configuration.
public struct OwnerObjectEdit: Equatable {
    public let cipher: String
    public let revision: Int64?
    public var label: String
    public var preset: Int?
    public var phone: String
    public var webhookURL: String
    public var webhookSecret: String
    public var webhookMode: String
    public var webhookToggle: Bool
    public var local: OwnerObjectLocalConfiguration

    public init(object: OwnerObject, masterKey: Data) throws {
        let metadata = try object.metadata(masterKey: masterKey)
        cipher = object.cipher; revision = object.revision
        label = metadata["label"] as? String ?? ""
        let avatar = metadata["avatar_type"] as? String ?? ""
        preset = avatar.hasPrefix("preset:") ? Int(avatar.dropFirst(7)) : nil
        phone = object.localPhone ?? ""
        webhookURL = object.routing["webhook_url"] ?? ""
        webhookSecret = object.routing["webhook_secret"] ?? ""
        webhookMode = object.routing["webhook_mode"] ?? "phone"
        webhookToggle = (metadata["wh_toggle"] as? Int) == 1
        local = object.localConfiguration ?? OwnerObjectLocalConfiguration()
    }
}

/// Retained until an authenticated snapshot acknowledges the exact update.
/// A rejected/unsent edit can restore its original private values as well as
/// its cipher. An uncertain, transmitted mutation cannot be cancelled/replayed.
public struct OwnerObjectEditBaseline: Codable, Equatable {
    public let cipher: String
    public let phone: String?
    public let routing: [String: String]
    public let local: OwnerObjectLocalConfiguration?
    public let avatarCipher: String?
    public init(object: OwnerObject) {
        cipher = object.cipher; phone = object.localPhone; routing = object.routing
        local = object.localConfiguration; avatarCipher = object.avatarCipher
    }
}

public extension OwnerObject {
    mutating func updateConfiguration(_ draft: OwnerObjectEdit, masterKey: Data) throws {
        guard cipher == draft.cipher, revision == draft.revision, pending == nil, !hasKeyRotation,
              numberID != nil, revision != nil, available != false else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 64, !label.contains("\n"), !label.contains("\r"),
              draft.preset.map({ (0...7).contains($0) }) ?? true else {
            throw GuestCrypto.Failure.invalidEnvelope
        }
        try draft.local.validate()
        var contents = try metadata(masterKey: masterKey)
        contents["label"] = label
        if let preset = draft.preset { contents["avatar_type"] = "preset:" + String(preset) }
        var nextPhone = localPhone, nextRouting = routing
        var routeChange: [String: String]?
        if kind == "call" {
            let normalized = draft.phone.filter { !" -()".contains($0) }
            let digits = normalized.hasPrefix("+") ? normalized.dropFirst() : normalized[...]
            guard !digits.isEmpty, normalized.utf8.count <= 64,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw GuestCrypto.Failure.invalidEnvelope }
            nextPhone = normalized
        }
        if kind == "webhook" {
            guard ["phone", "server"].contains(draft.webhookMode),
                  let url = URLComponents(string: draft.webhookURL), let host = url.host, !host.isEmpty,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  !draft.webhookSecret.isEmpty, draft.webhookSecret.utf8.count <= 1024 else {
                throw GuestCrypto.Failure.invalidEnvelope
            }
            nextRouting = ["webhook_mode": draft.webhookMode, "webhook_url": draft.webhookURL,
                           "webhook_secret": draft.webhookSecret]
            routeChange = ["webhook_mode": draft.webhookMode]
            if draft.webhookMode == "server" {
                routeChange?["webhook_url"] = draft.webhookURL
                routeChange?["webhook_secret"] = draft.webhookSecret
            }
            if draft.webhookToggle { contents["wh_toggle"] = 1 } else { contents.removeValue(forKey: "wh_toggle") }
        }
        // Keep owner-only fields out of the shared encrypted object, including
        // after editing material imported from older Android backups.
        for field in ["phone", "webhook_url", "webhook_secret", "snap_url", "snap_val", "snap_hdr"] {
            contents.removeValue(forKey: field)
        }
        let key = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedKey)
        let nextCipher = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: contents, options: .sortedKeys))
        editBaseline = OwnerObjectEditBaseline(object: self)
        cipher = nextCipher; localPhone = nextPhone; routing = nextRouting
        localConfiguration = draft.local; pendingRouting = routeChange
        pending = .update; sent = false
    }

    mutating func cancelConfigurationUpdate() throws {
        guard pending == .update, !sent, let baseline = editBaseline else { throw GuestCrypto.Failure.invalidEnvelope }
        cipher = baseline.cipher; localPhone = baseline.phone; routing = baseline.routing
        localConfiguration = baseline.local; avatarCipher = baseline.avatarCipher
        editBaseline = nil; pendingRouting = nil; pendingHasAvatar = nil
        pending = nil; sent = false
    }
}
