import Foundation
import CommonCrypto
import Security
import LocalAuthentication

struct LocalActionCode: Codable {
    let salt: Data
    let verifier: Data
    var failures: Int = 0
    var lockedUntil: Date = .distantPast

    static func derive(_ code: String, salt: Data) throws -> Data {
        guard (4...8).contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }), salt.count == 16 else {
            throw KeychainStore.Failure(status: errSecParam)
        }
        let password = Array(code.utf8)
        var output = Data(count: 32)
        let status = output.withUnsafeMutableBytes { result in
            salt.withUnsafeBytes { salt in
                password.withUnsafeBytes { password in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count, salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 60_000,
                        result.baseAddress?.assumingMemoryBound(to: UInt8.self), result.count)
                }
            }
        }
        guard status == kCCSuccess else { throw KeychainStore.Failure(status: errSecInternalError) }
        return output
    }
    func matches(_ candidate: Data) -> Bool {
        guard candidate.count == verifier.count else { return false }
        return zip(candidate, verifier).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    mutating func failed() {
        failures = min(failures + 1, 100)
        if failures >= 5 {
            let pauses: [TimeInterval] = [30, 60, 300, 1800, 7200]
            lockedUntil = Date().addingTimeInterval(pauses[min(failures - 5, 4)])
        }
    }
}

/// Enrollment changes invalidate this item; device passcode cannot satisfy its ACL.
enum ActionBiometrics {
    static var available: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "current-set"]
    }
    static func enroll(service: String) throws {
        let query = query(service: service)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                        .biometryCurrentSet, &error) else {
            throw KeychainStore.Failure(status: errSecAuthFailed)
        }
        var item = query
        item[kSecValueData as String] = Data(UUID().uuidString.utf8)
        item[kSecAttrAccessControl as String] = access
        // Enrollment is called after setting a new PIN or verifying the current
        // one. Rebuild an invalidated current-set ACL rather than keeping a
        // permanently unusable duplicate after biometric enrollment changes.
        let deletion = SecItemDelete(query as CFDictionary)
        guard deletion == errSecSuccess || deletion == errSecItemNotFound else { throw KeychainStore.Failure(status: deletion) }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.Failure(status: status) }
    }
    static func authenticate(service: String) throws {
        let query = query(service: service)
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var item = query
        item[kSecReturnData as String] = true
        item[kSecUseAuthenticationContext as String] = context
        item[kSecUseOperationPrompt as String] = ProductText.string("ios_system_authentication_prompt")
        let status = SecItemCopyMatching(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.Failure(status: status) }
    }
}
