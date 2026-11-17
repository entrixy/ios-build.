import Foundation

/// MainActivity.handleInviteIntent: a manufacturer's claim code prepares a form;
/// its HTTPS origin, rather than the currently selected server, owns the device.
public struct DeviceClaimLink: Equatable {
    public let server: String
    public let code: String
    public static func recognizes(_ url: URL) -> Bool {
        (url.scheme?.lowercased() == "entrixy" && url.host?.lowercased() == "claim") ||
        (url.scheme?.lowercased() == "https" && url.path.hasPrefix("/claim"))
    }
    public static func parse(_ url: URL, selectedServer: String) throws -> Self {
        guard recognizes(url), url.absoluteString.utf8.count <= 4096,
              let parts = URLComponents(url:url,resolvingAgainstBaseURL:false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw GuestInvite.Failure.invalidLink }
        let query = parts.queryItems ?? []
        guard query.filter({ $0.name == "c" }).count == 1,
              let raw = query.first(where:{ $0.name == "c" })?.value else { throw GuestInvite.Failure.invalidLink }
        let code = raw.uppercased().filter { $0.isASCII && ($0.isHexDigit) }
        guard !code.isEmpty, code.utf8.count <= 128 else { throw GuestInvite.Failure.invalidLink }
        let host: String
        if parts.scheme?.lowercased() == "entrixy" {
            guard parts.port == nil, parts.path.isEmpty || parts.path == "/" else { throw GuestInvite.Failure.invalidLink }
            host = selectedServer
        } else {
            guard let name = parts.host else { throw GuestInvite.Failure.invalidServer }
            let bracketed = name.contains(":") && !name.hasPrefix("[") ? "[\(name)]" : name
            host = bracketed + (parts.port.map { ":\($0)" } ?? "")
        }
        // A query parameter must never redirect a factory claim to another host.
        return Self(server:try GuestInvite.normalizeServer(host),code:code)
    }
}
