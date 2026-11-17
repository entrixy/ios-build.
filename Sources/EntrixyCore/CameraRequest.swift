import Foundation

public struct CameraRequest: Equatable {
    public enum Media: Equatable { case image, multipartJPEG, nativeVideo, otherVideo }
    public let url: URL
    public let headers: [String:String]
    public let media: Media
    public let authenticated: Bool
    public init(configuration: ObjectCameraConfiguration, guestUserKey: String? = nil, localKeyID: String = "0", epoch: UInt64 = UInt64(max(0,Date().timeIntervalSince1970))) throws {
        try configuration.validate()
        guard configuration.enabled else { throw GuestCrypto.Failure.invalidEnvelope }
        // Exactly the Android camera placeholders: expose a public hash prefix,
        // never the guest signing key or bundle/owner/controller secret.
        let token = guestUserKey.map { String(GuestCrypto.hash(Data($0.utf8)).prefix(32)) } ?? ""
        guard localKeyID.utf8.count <= 64, localKeyID.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || $0 == "-") }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let value = configuration.url.replacingOccurrences(of:"{ts}",with:String(epoch))
            .replacingOccurrences(of:"{token}",with:token).replacingOccurrences(of:"{key_id}",with:localKeyID)
        guard let url = URL(string:value), var parts = URLComponents(url:url,resolvingAgainstBaseURL:false),
              parts.host?.isEmpty == false, ["http","https","rtsp","rtmp"].contains(parts.scheme?.lowercased() ?? "") else { throw GuestCrypto.Failure.invalidEnvelope }
        var headers: [String:String] = [:]
        if !configuration.authValue.isEmpty {
            switch configuration.authType {
            case "basic": headers["Authorization"] = "Basic " + Data(configuration.authValue.utf8).base64EncodedString()
            case "bearer": headers["Authorization"] = "Bearer " + configuration.authValue
            case "header": headers[configuration.authHeader] = configuration.authValue
            default: break
            }
        }
        if let user = parts.user {
            if headers["Authorization"] == nil { headers["Authorization"] = "Basic " + Data((user + ":" + (parts.password ?? "")).utf8).base64EncodedString() }
            parts.user = nil; parts.password = nil
        }
        guard let address = parts.url else { throw GuestCrypto.Failure.invalidEnvelope }; self.url = address
        self.headers = headers
        authenticated = !headers.isEmpty
        let path = parts.path.lowercased(), scheme = parts.scheme?.lowercased()
        if scheme == "rtsp" || scheme == "rtmp" || [".mpd",".webm",".mkv"].contains(where:path.hasSuffix) { media = .otherVideo }
        else if [".m3u8",".mp4",".mov",".m4v"].contains(where:path.hasSuffix) { media = .nativeVideo }
        else { media = configuration.contentType == "mjpeg" ? .multipartJPEG : .image }
    }
    public func allowsRedirect(to destination: URL) -> Bool {
        guard let from = URLComponents(url:url,resolvingAgainstBaseURL:false),
              let to = URLComponents(url:destination,resolvingAgainstBaseURL:false),
              ["http","https"].contains(to.scheme?.lowercased() ?? ""), to.user == nil, to.password == nil else { return false }
        func port(_ parts: URLComponents) -> Int { parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80) }
        return from.scheme?.lowercased() == to.scheme?.lowercased() && from.host?.lowercased() == to.host?.lowercased() && port(from) == port(to)
    }
}

/// Bounded JPEG extraction for HTTP multipart streams. The parser deliberately
/// ignores multipart metadata; only complete JPEG marker-delimited frames leave
/// it. This cannot turn an HTML error/unfinished response into a valid frame.
public struct CameraJPEGFrames {
    public enum Failure: Error { case oversizedFrame }
    private enum State { case outside, markerPrefix, markerCode, lengthHigh(UInt8), lengthLow(UInt8,UInt8), segment(Int,Bool), entropy, entropyMarker }
    private var state = State.outside
    private var frame = Data()
    private var outsideFF = false
    public let maximumBytes: Int
    public init(maximumBytes: Int = 8_388_608) { self.maximumBytes = max(1024,maximumBytes) }
    public mutating func receive(_ byte: UInt8) throws -> Data? {
        if case .outside = state {
            if outsideFF, byte == 0xd8 { frame = Data([0xff,0xd8]); state = .markerPrefix; outsideFF = false }
            else { outsideFF = byte == 0xff }
            return nil
        }
        frame.append(byte)
        guard frame.count <= maximumBytes else { reset(); throw Failure.oversizedFrame }
        switch state {
        case .outside: break
        case .markerPrefix:
            if byte == 0xff { state = .markerCode } else { reset() }
        case .markerCode, .entropyMarker:
            let entropy: Bool
            if case .entropyMarker = state { entropy = true } else { entropy = false }
            if byte == 0xff { break }
            if byte == 0xd9 { let result = frame; reset(); return result }
            if entropy && (byte == 0 || (0xd0...0xd7).contains(byte)) { state = .entropy }
            else if byte == 0x01 || (0xd0...0xd7).contains(byte) { state = .markerPrefix }
            else if byte == 0 || byte == 0xd8 { reset() }
            else { state = .lengthHigh(byte) }
        case .lengthHigh(let marker): state = .lengthLow(marker,byte)
        case .lengthLow(let marker,let high):
            let count = Int(high)*256+Int(byte)-2
            if count < 0 { reset() }
            else if count == 0 { state = marker == 0xda ? .entropy : .markerPrefix }
            else { state = .segment(count,marker == 0xda) }
        case .segment(let left,let entropy):
            state = left == 1 ? (entropy ? .entropy : .markerPrefix) : .segment(left-1,entropy)
        case .entropy: if byte == 0xff { state = .entropyMarker }
        }
        return nil
    }
    private mutating func reset() { frame.removeAll(keepingCapacity:true); state = .outside; outsideFF = false }
}
