import Foundation

/// Offline material remains owner-authenticated AES-GCM ciphertext under K_guest.
/// Cached access is still bounded by controller-verified token expiry/revocation.
public struct GuestBLECache: Codable {
    public private(set) var revision: UUID
    public private(set) var cipher: String
    public private(set) var maximumEpoch: UInt64
    public private(set) var revocations: [BLERevocation]?
    public private(set) var usedProofs: [String]
    public init(bundle: Data, snapshot: Data, key: Data, epoch: UInt64) throws {
        revision = UUID(); maximumEpoch = epoch; usedProofs = []
        cipher = try Self.seal(bundle: bundle, snapshot: snapshot, key: key)
    }
    private static func seal(bundle: Data, snapshot: Data, key: Data) throws -> String {
        guard bundle.count <= 1_048_576, snapshot.count <= 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
        _ = try GuestObjects.decode(bundle: bundle, snapshot: snapshot)
        let bytes = try JSONSerialization.data(withJSONObject: ["bundle": bundle.base64EncodedString(), "snapshot": snapshot.base64EncodedString()], options: .sortedKeys)
        return try GuestCrypto.encrypt(key: key, plaintext: bytes)
    }
    public func open(key: Data) throws -> (bundle: Data, snapshot: Data) {
        guard cipher.utf8.count <= 4_000_000, usedProofs.count <= 64, Set(usedProofs).count == usedProofs.count,
              usedProofs.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else { throw GuestCrypto.Failure.invalidEnvelope }
        let records = revocations ?? []
        guard records.count <= 500, Set(records.map(\.id)).count == records.count else { throw GuestCrypto.Failure.invalidEnvelope }
        for record in records { try record.validate() }
        let clear = try GuestCrypto.decrypt(key: key, envelope: cipher)
        guard let contents = try JSONSerialization.jsonObject(with: clear) as? [String: String],
              let b = contents["bundle"], let bundle = Data(base64Encoded: b), bundle.count <= 1_048_576,
              let s = contents["snapshot"], let snapshot = Data(base64Encoded: s), snapshot.count <= 1_048_576 else { throw GuestCrypto.Failure.invalidEnvelope }
        return (bundle, snapshot)
    }
    public mutating func refresh(bundle: Data, snapshot: Data, key: Data, epoch: UInt64) throws {
        let old = try open(key: key)
        if old.bundle != bundle || old.snapshot != snapshot {
            cipher = try Self.seal(bundle: bundle, snapshot: snapshot, key: key); revision = UUID()
        }
        maximumEpoch = max(maximumEpoch, epoch)
    }
    public mutating func mergeRevocations(_ records: [BLERevocation]) throws {
        revocations = try BLERevocation.merge(records, into: revocations ?? [], limit: 500)
    }
    public mutating func acknowledgeRevocation(_ record: BLERevocation, code: UInt8) throws {
        guard let i = revocations?.firstIndex(where: { $0.id == record.id && $0.version == record.version && $0.signature == record.signature }) else { throw GuestCrypto.Failure.invalidEnvelope }
        try revocations![i].receiveControllerResult(code)
    }
    public mutating func consume(proof: String, epoch: UInt64) throws {
        guard proof.utf8.count == 64, proof.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !usedProofs.contains(proof) else { throw BLECommandSession.Failure.invalidPhase }
        maximumEpoch = max(maximumEpoch, epoch)
        usedProofs = Array((usedProofs + [proof]).suffix(64))
    }
}
