import Foundation
#if canImport(CryptoKit)
import CryptoKit
import CommonCrypto
#else
import Crypto
import _CryptoExtras
#endif

/// Android Backup.kt v1 container. Application payload schema is validated separately.
public enum BackupEnvelope {
    public enum Failure: Error { case invalidFormat, invalidPassword, passwordOrDamage }
    public static let maxPayloadSize = 16_777_216
    private static let rounds = 600_000
    private static let magic = Data("ENTRIXY1".utf8)

    public static func seal(_ plaintext: Data, password: String) throws -> Data {
        guard password.count >= 8, password.utf8.count <= 1024 else { throw Failure.invalidPassword }
        guard plaintext.count <= maxPayloadSize else { throw Failure.invalidFormat }
        let salt = GuestCrypto.randomBytes(count: 16), nonce = GuestCrypto.randomBytes(count: 12)
        var header = magic + Data([1, 1])
        header.append(contentsOf: [UInt8(rounds >> 24), UInt8((rounds >> 16) & 255), UInt8((rounds >> 8) & 255), UInt8(rounds & 255)])
        header.append(salt); header.append(nonce)
        let key = try derive(password, salt: salt, rounds: rounds)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        return header + sealed.ciphertext + sealed.tag
    }

    public static func open(_ blob: Data, password: String) throws -> Data {
        guard blob.count >= 58, blob.count <= maxPayloadSize + 58, blob.prefix(8) == magic,
              blob[8] == 1, blob[9] == 1, password.utf8.count <= 1024 else { throw Failure.invalidFormat }
        let iterations = blob[10..<14].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (10_000...5_000_000).contains(iterations) else { throw Failure.invalidFormat }
        let salt = Data(blob[14..<30]), nonce = Data(blob[30..<42]), header = Data(blob.prefix(42))
        let key = try derive(password, salt: salt, rounds: Int(iterations))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: blob[42..<(blob.count - 16)], tag: blob.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header)
        } catch { throw Failure.passwordOrDamage }
    }

    private static func derive(_ password: String, salt: Data, rounds: Int) throws -> Data {
        #if canImport(CryptoKit)
        let bytes = Array(password.utf8)
        var result = Data(count: 32)
        let status = result.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { salt in
                bytes.withUnsafeBytes { password in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds), output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.invalidFormat }
        return result
        #else
        // Android legacy files accept 10k..5M; the bounds are checked before KDF work.
        let key = try KDF.Insecure.PBKDF2.deriveKey(from: Data(password.utf8), salt: salt, using: .sha256, outputByteCount: 32, unsafeUncheckedRounds: rounds)
        return key.withUnsafeBytes { Data($0) }
        #endif
    }
}
