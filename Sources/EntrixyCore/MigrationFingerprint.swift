import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum MigrationFingerprint {
    public static func ios(identity: Data, server: String) throws -> String {
        guard identity.count == 32 else { throw GuestCrypto.Failure.invalidKey }
        return GuestCrypto.hash(identity + Data(try GuestInvite.normalizeServer(server).utf8))
    }
    public static func android(seed: String, server: String) throws -> String {
        guard !seed.isEmpty, seed.utf8.count <= 1024 else { throw GuestCrypto.Failure.invalidKey }
        let message = Data(("entrixy-fp-v2|" + (try GuestInvite.normalizeServer(server))).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(seed.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
