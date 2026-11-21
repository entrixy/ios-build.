import Foundation

public enum OwnerRegistrationPhase: String, Codable {
    case prepared, sent, rejected
}
public struct OwnerAccountLinkIntent: Codable, Equatable {
    public let email: String?
    public var sent = false
    public init(email: String?) { self.email = email }
}
/// Server-private preferences. Neither password nor sign-in token is retained.
public struct OwnerServerSettings: Codable, Equatable {
    public var accessCode = ""
    public var accountEmail: String?
    public var pendingAccount: OwnerAccountLinkIntent?
    public var deletionReceipt: DataDeletionReceipt?
    public init() {}
    public func validate() throws {
        try deletionReceipt?.validate()
        guard accessCode.utf8.count <= 8192,
              [accountEmail,pendingAccount?.email].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\r") && !$0.contains("\n") }) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}

public extension OwnerAccount {
    /// Missing phase on an old pending registration is ambiguous, never proof
    /// that no request was sent. Only a new preparation or definitive rejection
    /// allows another explicit registration attempt with the SAME local master.
    var canRegisterSafely: Bool { credentials == nil && [.prepared,.rejected].contains(registrationPhase) }
    mutating func markRegistrationSent() throws {
        guard canRegisterSafely else { throw GuestCrypto.Failure.invalidEnvelope }
        registrationPhase = .sent
    }
    mutating func rejectRegistration() throws {
        guard credentials == nil, registrationPhase == .sent else { throw GuestCrypto.Failure.invalidEnvelope }
        registrationPhase = .rejected
        serverSettings?.pendingAccount = nil
    }
    /// Only a local transport preflight rejection proves no request left this
    /// phone. A network error or a server error must keep the sent reservation.
    mutating func resetUnsentRegistration() throws {
        guard credentials == nil, registrationPhase == .sent else { throw GuestCrypto.Failure.invalidEnvelope }
        registrationPhase = .prepared
        serverSettings?.pendingAccount?.sent = false
    }
    mutating func reconcileAccount(_ snapshot: OwnerSnapshot) throws {
        guard snapshot.accountSpecified else { return }
        var settings = serverSettings ?? OwnerServerSettings()
        settings.accountEmail = snapshot.accountEmail
        if let pending = settings.pendingAccount, pending.sent,
           pending.email?.lowercased() == snapshot.accountEmail?.lowercased() { settings.pendingAccount = nil }
        try settings.validate(); serverSettings = settings
    }
}
