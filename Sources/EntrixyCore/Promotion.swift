import Foundation

/// Android PromoData: content comes only from Entrixy's catalogue, never an
/// access server. No owner credential or access fingerprint enters this model.
public struct Promotion: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let type: String
    public let title: String
    public let body: String?
    public let iconURL: URL?
    public let bannerURL: URL?
    public let buttonText: String?
    public let buttonURL: String?
    public let backgroundColor: String?
    public let textColor: String?
    public let displayMode: String
    public let cacheTTL: Int
    public let height: Int

    public init(json: [String: Any]) throws {
        func text(_ name: String, limit: Int = 4096) throws -> String? {
            guard let value = json[name], !(value is NSNull) else { return nil }
            guard let value = value as? String, value.utf8.count <= limit else { throw GuestCrypto.Failure.invalidEnvelope }
            return value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || value == "null" ? nil : value
        }
        func image(_ name: String) throws -> URL? {
            guard let value = try text(name), let url = URLComponents(string:value),
                  url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
                if try text(name) != nil { throw GuestCrypto.Failure.invalidEnvelope }; return nil
            }
            return url.url
        }
        id = try OwnerObject.replyID(json["id"])
        type = try text("type",limit:32) ?? "standard"
        title = try text("title",limit:1024) ?? ""
        body = try text("body"); iconURL = try image("icon_url"); bannerURL = try image("banner_url")
        buttonText = try text("button_text",limit:512); buttonURL = try text("button_url")
        backgroundColor = try text("bg_color",limit:16); textColor = try text("text_color",limit:16)
        displayMode = try text("display_mode",limit:32) ?? "infinite"
        cacheTTL = json["cache_ttl"] as? Int ?? 900; height = json["height_dp"] as? Int ?? 96
        try validate()
    }
    public func validate() throws {
        guard id > 0, title.utf8.count <= 1024, !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              (body?.utf8.count ?? 0) <= 4096, (buttonText?.utf8.count ?? 0) <= 512,
              (buttonURL?.utf8.count ?? 0) <= 4096, type.utf8.count <= 32,
              ["infinite","until_click","date_range"].contains(displayMode), (0...604800).contains(cacheTTL), (1...2000).contains(height) else { throw GuestCrypto.Failure.invalidEnvelope }
        for url in [iconURL,bannerURL].compactMap({ $0 }) {
            guard url.absoluteString.utf8.count <= 4096, let value = URLComponents(url:url,resolvingAgainstBaseURL:false),
                  value.scheme?.lowercased() == "https", value.host != nil, value.user == nil, value.password == nil, value.fragment == nil else { throw GuestCrypto.Failure.invalidEnvelope }
        }
    }
    public var destination: URL? {
        guard buttonURL?.isEmpty == false else { return nil }
        return URL(string:"https://entrixy.com/api/go.php?pid=\(id)")
    }
}

/// Separate, excluded-from-backup, per-install catalogue state. This UUID is
/// unrelated to device hardware, guest/owner keys, account or control identity.
public struct PromotionState: Codable, Equatable, Sendable {
    public let installID: UUID
    public let firstSeen: Date
    public var cached: Promotion?
    public var cachedAt: Date?
    public var cachedLanguage: String?
    public var clicked: [Int]
    public var views: [String: Int]
    public var sentDay: String?
    public init(now: Date = Date()) {
        installID = UUID(); firstSeen = now; clicked = []; views = [:]
    }
    public func validate() throws {
        guard firstSeen.timeIntervalSince1970.isFinite, firstSeen.timeIntervalSince1970 > 0,
              cachedAt.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 }) ?? true,
              clicked.count <= 1000, Set(clicked).count == clicked.count, clicked.allSatisfy({ $0 > 0 }),
              views.count <= 1000, views.allSatisfy({ Int($0.key).map({ $0 > 0 }) == true && (0...10000).contains($0.value) }),
              cachedLanguage.map({ ["en","zh","es","fr","pt","ru","de"].contains($0) }) ?? true,
              sentDay.map({ $0.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}$",options:.regularExpression) != nil }) ?? true else { throw GuestCrypto.Failure.invalidEnvelope }
        try cached?.validate()
    }
    public var visible: Promotion? {
        guard let cached, cached.displayMode != "until_click" || !clicked.contains(cached.id) else { return nil }; return cached
    }
    public func needsRefresh(now: Date) -> Bool {
        guard let cachedAt else { return true }
        let age = now.timeIntervalSince(cachedAt)
        return age < 0 || age >= Double(cached?.cacheTTL ?? 900)
    }
    public func request(language: String, version: String, tags: Set<String>, now: Date) throws -> Data {
        try validate()
        guard ["en","zh","es","fr","pt","ru","de"].contains(language), version.utf8.count <= 128,
              tags.isSubset(of:["has_call","has_webhook","has_device","has_guest"]) else { throw GuestCrypto.Failure.invalidEnvelope }
        let elapsed = now.timeIntervalSince(firstSeen)
        guard elapsed.isFinite else { throw GuestCrypto.Failure.invalidEnvelope }
        let age = Int(max(0,min(36500,elapsed/86400)))
        let all = age < 7 ? tags.union(["new_install"]) : tags
        return try JSONSerialization.data(withJSONObject:["lang":language,"version":version,"install_id":installID.uuidString.lowercased(),
            "age_days":age,"tags":all.sorted()],options:.sortedKeys)
    }
}
