import Foundation

/// The native player receives only local resource URLs. Remote playlist URLs,
/// authorization, cookies and user-selected camera secrets never enter it.
public enum CameraHLSPlaylist {
    public static func rewriting(_ data: Data,base: URL,resource: (URL) throws -> URL) throws -> Data {
        guard data.count <= 1_048_576, var text = String(data:data,encoding:.utf8) else { throw GuestCrypto.Failure.invalidEnvelope }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        guard text.hasPrefix("#EXTM3U"), !text.utf8.contains(0) else { throw GuestCrypto.Failure.invalidEnvelope }
        let attributes = try NSRegularExpression(pattern:#"\bURI="([^"]+)""#)
        var resourceCount = 0
        func mapped(_ value: String) throws -> String {
            resourceCount += 1
            guard resourceCount <= 32768, value.utf8.count <= 8192, let url = URL(string:value,relativeTo:base)?.absoluteURL,
                  ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil else { throw GuestCrypto.Failure.invalidEnvelope }
            let result = try resource(url).absoluteString
            guard result.utf8.count <= 32768 else { throw GuestCrypto.Failure.invalidEnvelope }
            return result
        }
        var result = Data()
        for (index,original) in text.components(separatedBy:.newlines).enumerated() {
            var line = original.trimmingCharacters(in:.whitespaces)
            if !line.isEmpty, !line.hasPrefix("#") { line = try mapped(line) }
            else if !line.isEmpty {
                let matches = attributes.matches(in:line,range:NSRange(line.startIndex...,in:line))
                if line.contains("URI="), matches.isEmpty { throw GuestCrypto.Failure.invalidEnvelope }
                for match in matches.reversed() {
                    guard let range = Range(match.range(at:1),in:line) else { throw GuestCrypto.Failure.invalidEnvelope }
                    let replacement = try mapped(String(line[range])); line.replaceSubrange(range,with:replacement)
                    guard line.utf8.count <= 4_194_304 else { throw GuestCrypto.Failure.invalidEnvelope }
                }
            }
            let bytes = Data(line.utf8)
            guard result.count + bytes.count + (index == 0 ? 0 : 1) <= 4_194_304 else { throw GuestCrypto.Failure.invalidEnvelope }
            if index > 0 { result.append(10) }; result.append(bytes)
        }
        return result
    }
}

/// One request per loopback connection, no request bodies, multiple ranges or
/// arbitrary URL forwarding. The actual target comes from an opaque local map.
public struct CameraVideoHTTPRequest {
    public let method: String
    public let path: String
    public let host: String
    public let range: String?
    public init(_ data: Data) throws {
        guard data.count <= 32768, let text = String(data:data,encoding:.ascii), text.hasSuffix("\r\n\r\n") else { throw GuestCrypto.Failure.invalidEnvelope }
        let lines = text.components(separatedBy:"\r\n")
        let first = lines[0].split(separator:" ",omittingEmptySubsequences:false)
        guard first.count == 3, ["GET","HEAD"].contains(String(first[0])), first[1].hasPrefix("/"), !first[1].contains("?"),
              ["HTTP/1.0","HTTP/1.1"].contains(String(first[2])) else { throw GuestCrypto.Failure.invalidEnvelope }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let split = line.firstIndex(of:":") else { throw GuestCrypto.Failure.invalidEnvelope }
            let name = line[..<split].lowercased(), value = line[line.index(after:split)...].trimmingCharacters(in:.whitespaces)
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), headers[name] == nil,
                  value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw GuestCrypto.Failure.invalidEnvelope }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0",
              let host = headers["host"], !host.isEmpty else { throw GuestCrypto.Failure.invalidEnvelope }
        if let range = headers["range"] {
            let pattern = #"^bytes=(?:[0-9]{1,19}-[0-9]{0,19}|-[0-9]{1,19})$"#
            guard range.range(of:pattern,options:.regularExpression) != nil else { throw GuestCrypto.Failure.invalidEnvelope }
        }
        method = String(first[0]); path = String(first[1]); self.host = host; range = headers["range"]
    }
}
