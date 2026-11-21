import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Bounded RTSP/interleaved-RTP framing. An RTP packet may contain arbitrary
/// CRLF bytes; it must never be interpreted as a control response.
public struct CameraRTSPFramer {
    public enum Frame { case packet(Data), message(CameraRTSPMessage) }
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Frame] {
        guard buffer.count + data.count <= 2_097_152 else { throw GuestCrypto.Failure.invalidEnvelope }
        buffer.append(data)
        var frames: [Frame] = []
        while !buffer.isEmpty {
            if buffer[buffer.startIndex] == 36 {
                guard buffer.count >= 4 else { break }
                let bytes = [UInt8](buffer.prefix(4)); let count = 4 + Int(bytes[2]) * 256 + Int(bytes[3])
                guard buffer.count >= count else { break }
                frames.append(.packet(Data(buffer.prefix(count)))); buffer.removeFirst(count)
            } else {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= 32768 else { throw GuestCrypto.Failure.invalidEnvelope }; break
                }
                let length = buffer.distance(from: buffer.startIndex, to: end.upperBound)
                guard length <= 32768 else { throw GuestCrypto.Failure.invalidEnvelope }
                var message = try CameraRTSPMessage(header: Data(buffer.prefix(length)))
                let total = length + message.contentLength
                guard buffer.count >= total else { break }
                message.body = Data(buffer.dropFirst(length).prefix(message.contentLength))
                frames.append(.message(message)); buffer.removeFirst(total)
            }
        }
        return frames
    }
}

public struct CameraRTSPMessage {
    public var start: String
    public var headers: [String: String]
    public var body = Data()
    public let contentLength: Int
    public init(header: Data) throws {
        guard header.count <= 32768, let text = String(data: header, encoding: .utf8), text.hasSuffix("\r\n\r\n"),
              !text.utf8.contains(0) else { throw GuestCrypto.Failure.invalidEnvelope }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty, first.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw GuestCrypto.Failure.invalidEnvelope }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw GuestCrypto.Failure.invalidEnvelope }
            let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  fields[name] == nil, !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw GuestCrypto.Failure.invalidEnvelope }
            fields[name] = value
        }
        let lengthText = fields["content-length"] ?? "0"
        guard lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText), length <= 1_048_576,
              let cseq = fields["cseq"], !cseq.isEmpty, cseq.count <= 12, cseq.utf8.allSatisfy({ (48...57).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        start = first; headers = fields; contentLength = length
    }
    public var encoded: Data {
        var copy = headers; copy["content-length"] = String(body.count)
        let head = start + "\r\n" + copy.keys.sorted().map { $0 + ": " + copy[$0]! + "\r\n" }.joined() + "\r\n"
        return Data(head.utf8) + body
    }
    public var request: (method: String, uri: String)? {
        let pieces = start.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[2] == "RTSP/1.0", ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "PAUSE", "TEARDOWN", "GET_PARAMETER"].contains(String(pieces[0])) else { return nil }
        return (String(pieces[0]), String(pieces[1]))
    }
    public var status: Int? {
        let pieces = start.split(separator: " ")
        guard pieces.count >= 2, pieces[0] == "RTSP/1.0", let code = Int(pieces[1]), (100...599).contains(code) else { return nil }
        return code
    }
}

/// Read-only RTSP Digest is computed by the pinned-origin bridge, rather than
/// by a decoder signing its unrelated local URL. Credentials never reach VLC.
public struct CameraRTSPDigest {
    private let realm: String, nonce: String, algorithm: String, opaque: String?, qop: Bool
    public init(challenge: String) throws {
        guard challenge.utf8.count <= 8192, challenge.lowercased().hasPrefix("digest ") else { throw GuestCrypto.Failure.invalidEnvelope }
        let raw = String(challenge.dropFirst(7))
        let regex = try NSRegularExpression(pattern: #"(?:^|,)\s*([A-Za-z0-9_-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))\s*"#)
        var fields: [String: String] = [:], consumed = 0
        for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard match.range.location == consumed, let keyRange = Range(match.range(at: 1), in: raw) else { throw GuestCrypto.Failure.invalidEnvelope }
            let valueRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            guard let range = Range(valueRange, in: raw) else { throw GuestCrypto.Failure.invalidEnvelope }
            let name = raw[keyRange].lowercased(); guard fields[name] == nil else { throw GuestCrypto.Failure.invalidEnvelope }
            fields[name] = String(raw[range]).replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
            consumed = NSMaxRange(match.range)
        }
        guard consumed == raw.utf16.count, let realm = fields["realm"], let nonce = fields["nonce"], !nonce.isEmpty,
              realm.count <= 4096, nonce.count <= 4096 else { throw GuestCrypto.Failure.invalidEnvelope }
        let algorithm = (fields["algorithm"] ?? "MD5").uppercased()
        guard ["MD5", "MD5-SESS", "SHA-256", "SHA-256-SESS"].contains(algorithm) else { throw GuestCrypto.Failure.invalidEnvelope }
        if let qop = fields["qop"] { guard qop.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "auth" }) else { throw GuestCrypto.Failure.invalidEnvelope } }
        self.realm = realm; self.nonce = nonce; self.algorithm = algorithm; opaque = fields["opaque"]; qop = fields["qop"] != nil
    }
    public func authorization(basic: String, method: String, uri: String, count: UInt32, cnonce: String) throws -> String {
        guard basic.hasPrefix("Basic "), let bytes = Data(base64Encoded: String(basic.dropFirst(6))), let credentials = String(data: bytes, encoding: .utf8), let colon = credentials.firstIndex(of: ":"),
              count > 0, !cnonce.isEmpty, cnonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let user = String(credentials[..<colon]), password = String(credentials[credentials.index(after: colon)...])
        func hash(_ text: String) -> String {
            let data = Data(text.utf8)
            return algorithm.hasPrefix("MD5") ? Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func quote(_ value: String) throws -> String {
            guard !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw GuestCrypto.Failure.invalidEnvelope }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var ha1 = hash(user + ":" + realm + ":" + password)
        if algorithm.hasSuffix("-SESS") { ha1 = hash(ha1 + ":" + nonce + ":" + cnonce) }
        let ha2 = hash(method + ":" + uri), nc = String(format: "%08x", count)
        let response = hash(ha1 + ":" + nonce + ":" + (qop ? nc + ":" + cnonce + ":auth:" : "") + ha2)
        var result = "Digest username=" + (try quote(user)) + ", realm=" + (try quote(realm)) + ", nonce=" + (try quote(nonce)) + ", uri=" + (try quote(uri)) + ", response=\"" + response + "\", algorithm=" + algorithm
        if qop { result += ", qop=auth, nc=" + nc + ", cnonce=" + (try quote(cnonce)) }
        else if algorithm.hasSuffix("-SESS") { result += ", cnonce=" + (try quote(cnonce)) }
        if let opaque { result += ", opaque=" + (try quote(opaque)) }
        return result
    }
}
