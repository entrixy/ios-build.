import Foundation

public extension OwnerObject {
    mutating func updateAvatar(preset: Int?, jpeg: Data?, masterKey: Data) throws {
        guard pending == nil, !hasKeyRotation, numberID != nil, revision != nil, available != false,
              (preset != nil) != (jpeg != nil), preset.map({ (0...7).contains($0) }) ?? true,
              jpeg.map({ !$0.isEmpty && $0.count <= 524_288 }) ?? true else { throw GuestCrypto.Failure.invalidEnvelope }
        let key = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedKey)
        let image = try jpeg.map { try GuestCrypto.encrypt(key: key, plaintext: $0) }
        var metadata = try metadata(masterKey: masterKey)
        metadata["avatar_type"] = preset.map { "preset:" + String($0) } ?? "file"
        let next = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys))
        editBaseline = OwnerObjectEditBaseline(object: self)
        avatarCipher = image; cipher = next; pendingHasAvatar = true; pending = .update; sent = false
    }
    func avatar(masterKey: Data) throws -> Data? {
        guard let avatarCipher, try metadata(masterKey: masterKey)["avatar_type"] as? String == "file" else { return nil }
        let key = try GuestCrypto.decrypt(key: masterKey, envelope: wrappedKey)
        return try GuestCrypto.decrypt(key: key, envelope: avatarCipher)
    }
}

public extension ObjectCatalogPreferences {
    mutating func setAvatar(_ target: ObjectReference, preset: Int?, jpeg: Data?, localKey: Data) throws {
        guard case .received = target, (preset != nil) != (jpeg != nil),
              preset.map({ (0...7).contains($0) }) ?? true,
              jpeg.map({ !$0.isEmpty && $0.count <= 524_288 }) ?? true else { throw GuestCrypto.Failure.invalidEnvelope }
        try target.validate()
        var value = presentation(for: target)
        value.avatarPreset = preset
        value.avatarCipher = try jpeg.map { try GuestCrypto.encrypt(key: localKey, plaintext: $0) }
        var draft = self; draft.received[target.id] = value
        try draft.validate(); self = draft
    }
    func avatar(_ target: ObjectReference, localKey: Data) throws -> Data? {
        guard let cipher = presentation(for: target).avatarCipher else { return nil }
        return try GuestCrypto.decrypt(key: localKey, envelope: cipher)
    }
}
