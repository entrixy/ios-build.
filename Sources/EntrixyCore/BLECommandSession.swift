import Foundation

/// One physical attempt. Callers durably store proofHash + journal BEFORE writing
/// the consumed frame. GATT write success is deliberately not a fire result.
public struct BLECommandSession {
    public enum Credential { case owner(Data), guest(BLEGuestGrant) }
    public enum Phase { case waiting, prepared, consumed, finished, cancelled }
    public private(set) var phase: Phase = .waiting
    public private(set) var proofHash: String?
    public private(set) var result: BLEFireResult?
    private let credential: Credential
    private let started: TimeInterval
    private var lastEpoch: UInt64
    private var challenged: TimeInterval?
    private var frame: Data?
    public init(credential: Credential, now: TimeInterval, epoch: UInt64) throws {
        guard now.isFinite, now >= 0 else { throw GuestCrypto.Failure.invalidEnvelope }
        switch credential {
        case .owner(let key): guard key.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        case .guest(let grant): try grant.validate(); guard grant.isValid(at: epoch) else { throw Failure.expired }
        }
        self.credential = credential; started = now; lastEpoch = epoch
    }
    public enum Failure: Error { case expired, invalidPhase }
    public mutating func prepare(nonce: Data, now: TimeInterval, epoch: UInt64) throws {
        lastEpoch = max(lastEpoch, epoch)
        guard phase == .waiting, now.isFinite, now >= started, now - started < 30, nonce.count == 8 else { throw Failure.invalidPhase }
        let key: Data
        switch credential {
        case .owner(let secret):
            key = secret; frame = try BLECrypto.ownerFire(ownerSecret: secret, nonce: nonce)
        case .guest(let grant):
            guard grant.isValid(at: lastEpoch) else { throw Failure.expired }
            key = grant.guestKey
            frame = try BLECrypto.guestFire(token: grant.token, ownerSignature: grant.ownerSignature, guestKey: key, nonce: nonce)
        }
        proofHash = GuestCrypto.hash(Data("entrixy-ble-proof-v1".utf8) + key + nonce)
        challenged = now; phase = .prepared
    }
    public mutating func consume(now: TimeInterval, epoch: UInt64) throws -> Data {
        lastEpoch = max(lastEpoch, epoch)
        guard phase == .prepared, let challenged, let frame, now.isFinite, now >= challenged,
              now - challenged < 5, now - started < 30 else { throw Failure.invalidPhase }
        if case .guest(let grant) = credential { guard grant.isValid(at: lastEpoch) else { throw Failure.expired } }
        phase = .consumed
        return frame
    }
    public mutating func receive(_ code: UInt8) -> BLEFireResult? {
        guard phase == .consumed, let result = BLEFireResult(rawValue: code) else { return nil }
        self.result = result; phase = .finished
        return result
    }
    public mutating func cancel() { if phase != .finished { phase = .cancelled }; frame = nil }
}
public enum BLEFireResult: UInt8, Codable {
    case accepted = 0, staleNonce = 1, expired = 2, badOwnerSignature = 3, badGuestSignature = 4
    case badLength = 5, derivationFailed = 6, badOwnerHMAC = 7, revoked = 8
    case open = 0x30, closed = 0x31, opening = 0x32, closing = 0x33
    public var succeeded: Bool { self == .accepted || rawValue >= 0x30 }
    public var message: String {
        switch self {
        case .accepted: return "Контроллер принял команду"
        case .open: return "Контроллер: открыто"
        case .closed: return "Контроллер: закрыто"
        case .opening: return "Контроллер: открывается"
        case .closing: return "Контроллер: закрывается"
        case .staleNonce: return "Контроллер отклонил устаревший запрос"
        case .expired: return "Срок доступа истёк"
        case .revoked: return "Доступ отозван на контроллере"
        case .badOwnerSignature, .badGuestSignature, .badOwnerHMAC: return "Контроллер отклонил подпись"
        case .badLength, .derivationFailed: return "Команда отклонена контроллером"
        }
    }
}
