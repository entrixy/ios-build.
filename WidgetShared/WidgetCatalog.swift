import Foundation

struct WidgetObject: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case ready, offline, connecting, neutral }
    let id: String
    let label: String
    let source: String
    let preset: Int
    let image: String?
    let status: Status
    let localCall: Bool
    let observedAt: Date
    func validate() -> Bool {
        Self.validID(id) && !label.isEmpty && label.utf8.count <= 1024 && source.utf8.count <= 128
        && (0...7).contains(preset) && (image.map(Self.validID) ?? true) && observedAt.timeIntervalSince1970.isFinite
    }
    static func validID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func currentStatus(at date: Date) -> Status {
        if status == .neutral || localCall { return status }
        let age = date.timeIntervalSince(observedAt)
        return age >= 0 && age < 15 ? status : .offline
    }
}

/// Presentation only. No key, URL, phone number, BLE secret, template, pending
/// physical command or installation identity is exported to the extension.
struct WidgetCatalog: Codable, Equatable {
    static let group = "group.com.entrixy.ios"
    static let kind = "EntrixyObject"
    var objects: [WidgetObject]
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group)?.appendingPathComponent("WidgetPresentation",isDirectory:true)
    }
    static func load(directory: URL? = Self.directory) -> Self {
        guard let directory else { return Self(objects:[]) }
        let file = directory.appendingPathComponent("catalog.json")
        guard let size = try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= 8_388_608,
              let data = try? Data(contentsOf:file), let value = try? JSONDecoder().decode(Self.self,from:data),
              value.objects.count <= 4000, value.objects.allSatisfy({ $0.validate() }),
              Set(value.objects.map(\.id)).count == value.objects.count else { return Self(objects:[]) }
        return value
    }
    static func imageURL(_ name: String, directory: URL? = Self.directory) -> URL? {
        guard WidgetObject.validID(name) else { return nil }
        return directory?.appendingPathComponent(name+".jpg")
    }
}
