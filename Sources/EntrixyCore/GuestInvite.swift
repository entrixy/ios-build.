import Foundation

public struct GuestInvite: Codable, Equatable, Identifiable {
    public let server: String
    public let userKey: String
    public let bundleKey: Data
    public var id: String { server + ":" + GuestCrypto.hash(Data(userKey.utf8)) }

    public enum Failure: Error { case invalidLink, invalidServer }

    public static func normalizeServer(_ value: String) throws -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("\\"),
              let u = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
              u.scheme == "https", u.user == nil, u.password == nil,
              u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/",
              let host = u.host, !host.isEmpty, host.unicodeScalars.allSatisfy({ $0.isASCII }),
              !host.contains(where: { $0.isWhitespace }),
              u.port == nil || (1...65535).contains(u.port!) else { throw Failure.invalidServer }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return bracketed.lowercased() + (u.port.map { ":\($0)" } ?? "")
    }

    /// Opening a link only prepares the import form; it never binds automatically.
    public static func incomingText(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: text), url.scheme?.lowercased() == "entrixy" {
            guard url.host == "key", url.user == nil, url.password == nil, url.port == nil,
                  url.path.isEmpty || url.path == "/", url.query == nil,
                  let fragment = url.percentEncodedFragment else { throw Failure.invalidLink }
            let candidate = "https://entrixy.com/key#" + fragment
            _ = try parse(candidate)
            return candidate
        }
        _ = try parse(text)
        return text
    }

    public static func parse(_ input: String, defaultServer: String = "entrixy.com") throws -> GuestInvite {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var blob = text
        var server = defaultServer
        if text.hasPrefix("https://") {
            guard let url = URLComponents(string: text), let fragment = url.fragment else { throw Failure.invalidLink }
            let parts = fragment.split(separator: "&", omittingEmptySubsequences: false)
            blob = String(parts[0])
            if let query = URLComponents(string: "https://placeholder/?" + parts.dropFirst().joined(separator: "&")),
               let declared = query.queryItems?.first(where: { $0.name == "h" })?.value {
                server = declared
            } else if let host = url.host {
                server = host + (url.port.map { ":\($0)" } ?? "")
            }
        } else if text.contains(":") || text.contains("/") { throw Failure.invalidLink }
        guard blob.count == 75, blob.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw Failure.invalidLink
        }
        let key = String(blob.prefix(32))
        let bundle = try GuestCrypto.decodeBase64URL(String(blob.dropFirst(32)))
        guard bundle.count == 32 else { throw Failure.invalidLink }
        return GuestInvite(server: try normalizeServer(server), userKey: key, bundleKey: bundle)
    }
}
