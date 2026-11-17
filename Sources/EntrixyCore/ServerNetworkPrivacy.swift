import Foundation

/// Prefs.BlockedNet / Vault.net_block. Network names stay inside local protected
/// state and encrypted guest bundles; they are not sent as server metadata.
public struct PrivacyNetwork: Codable, Equatable, Hashable {
    public let ssid: String
    public let bssid: String?
    private enum CodingKeys: String, CodingKey { case ssid = "s", bssid = "b" }
    public init(ssid: String, bssid: String? = nil) throws {
        guard !ssid.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              ssid.utf8.count <= 256, !ssid.contains(where:{ $0.isNewline || $0 == "\0" }) else { throw GuestCrypto.Failure.invalidEnvelope }
        self.ssid = ssid
        let address = bssid?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if let address, !address.isEmpty {
            guard address.range(of:"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$",options:.regularExpression) != nil,
                  address != "02:00:00:00:00:00" else { throw GuestCrypto.Failure.invalidEnvelope }
            self.bssid = address
        } else { self.bssid = nil }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        try self.init(ssid:c.decode(String.self,forKey:.ssid),bssid:c.decodeIfPresent(String.self,forKey:.bssid))
    }
    public static func decode(_ raw: Any?) throws -> [Self] {
        guard let raw else { return [] }
        guard let rows = raw as? [[String:Any]], rows.count <= 256 else { throw GuestCrypto.Failure.invalidEnvelope }
        return try rows.map { row in
            guard let name = row["s"] as? String, row["b"] == nil || row["b"] is String else { throw GuestCrypto.Failure.invalidEnvelope }
            return try Self(ssid:name,bssid:row["b"] as? String)
        }
    }
    public var wire: [String:String] { var row = ["s":ssid]; if let bssid { row["b"] = bssid }; return row }
    public func matches(ssid: String?, bssid: String?) -> Bool {
        if let ssid, self.ssid.caseInsensitiveCompare(ssid) == .orderedSame { return true }
        return self.bssid != nil && bssid != nil && self.bssid?.caseInsensitiveCompare(bssid!) == .orderedSame
    }
}

public enum ServerNetworkRoute: Equatable { case system, cellular, blocked }
public struct ServerNetworkDecision: Equatable {
    public let route: ServerNetworkRoute
    public let unknownWiFi: Bool
    public let ownRule: Bool
    public static func evaluate(own: [PrivacyNetwork], received: [PrivacyNetwork],
                                isWiFi: Bool?, ssid: String?, bssid: String?,
                                cellularAuthorized: Bool, constrainedRoutingAvailable: Bool) -> Self {
        let all = own + received
        guard !all.isEmpty else { return Self(route:.system,unknownWiFi:false,ownRule:false) }
        // iOS16 has no URLSession.proxyConfigurations. Do not let a default
        // URLSession change to a forbidden interface after a one-time check.
        guard constrainedRoutingAvailable else { return Self(route:.blocked,unknownWiFi:isWiFi != false && ssid == nil && bssid == nil,ownRule:!own.isEmpty) }
        if isWiFi == false { return Self(route:.system,unknownWiFi:false,ownRule:false) }
        let unknown = isWiFi == nil || ((ssid?.isEmpty ?? true) && (bssid?.isEmpty ?? true))
        let hit = all.contains { $0.matches(ssid:ssid,bssid:bssid) }
        guard unknown || hit else { return Self(route:.system,unknownWiFi:false,ownRule:false) }
        let ownHit = unknown ? !own.isEmpty : own.contains { $0.matches(ssid:ssid,bssid:bssid) }
        // Only an explicitly authorized cellular path may replace Wi-Fi. The
        // transport must require that interface; a failure never falls back.
        return Self(route:cellularAuthorized ? .cellular : .blocked,unknownWiFi:unknown,ownRule:ownHit)
    }
}

/// A bounded HTTP CONNECT header for the app's authenticated loopback proxy.
/// Opaque TLS bytes following the header are retained, never parsed or logged.
public struct ServerProxyConnect {
    public let server: String
    public let host: String
    public let port: UInt16
    public let remainder: Data
    public enum Failure: Error { case incomplete, invalid, unauthorized }
    public init(_ bytes: Data, authorization: String) throws {
        guard bytes.count <= 65536 else { throw Failure.invalid }
        let bytes = Data(bytes)
        guard let end = bytes.range(of:Data("\r\n\r\n".utf8)) else {
            if bytes.count > 16384 { throw Failure.invalid }; throw Failure.incomplete
        }
        guard end.upperBound <= 16384, let text = String(data:bytes[..<end.lowerBound],encoding:.utf8),
              text.utf8.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { throw Failure.invalid }
        let lines = text.components(separatedBy:"\r\n")
        guard lines.count <= 64 else { throw Failure.invalid }
        let request = lines[0].split(separator:" ",omittingEmptySubsequences:false)
        guard request.count == 3, request[0] == "CONNECT", request[2] == "HTTP/1.1",
              let parts = URLComponents(string:"https://" + request[1]),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, let name = parts.host, let port = parts.port, (1...65535).contains(port) else { throw Failure.invalid }
        let authority = String(request[1])
        let normalized = try GuestInvite.normalizeServer(authority)
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw Failure.invalid }
            let field = String(line[..<colon]).lowercased(), value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard !field.isEmpty, field.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  headers[field] == nil else { throw Failure.invalid }
            headers[field] = value
        }
        guard headers["transfer-encoding"] == nil,
              headers["content-length"].map({ $0 == "0" }) ?? true,
              headers["host"].map({ $0.caseInsensitiveCompare(authority) == .orderedSame }) ?? true else { throw Failure.invalid }
        let supplied = Data((headers["proxy-authorization"] ?? "").utf8), expected = Data(authorization.utf8)
        guard !expected.isEmpty, supplied.count == expected.count,
              zip(supplied,expected).reduce(UInt8(0),{ $0 | ($1.0 ^ $1.1) }) == 0 else { throw Failure.unauthorized }
        server = normalized; host = name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name
        self.port = UInt16(port); remainder = Data(bytes[end.upperBound...])
    }
}
