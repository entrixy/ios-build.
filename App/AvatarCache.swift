import Foundation
import ImageIO
import EntrixyCore

/// Keep only owner-encrypted envelopes on disk. Decrypted image bytes live in memory.
struct AvatarCache {
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EncryptedAvatars", isDirectory: true)
    }
    static func key(guestID: String, objectID: String) -> String {
        GuestCrypto.hash(Data((guestID + ":" + objectID).utf8))
    }
    func load(_ key: String) -> String? {
        let url = root.appendingPathComponent(key + ".cipher")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    func save(_ envelope: String, key: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(envelope.utf8).write(to: root.appendingPathComponent(key + ".cipher"), options: [.atomic, .completeFileProtection])
    }
    func remove(_ key: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(key + ".cipher")) }

    static func isImage(_ bytes: Data) -> Bool {
        guard bytes.count <= 524_288,
              let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(image) == 1,
              let values = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int,
              let height = values[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 4_194_304 else { return false }
        return true
    }
}
