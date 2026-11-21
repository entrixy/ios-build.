import Foundation

public enum DataDeletionScope: String, Codable, CaseIterable { case device, account }
public struct DataDeletionResult: Codable, Equatable {
    public enum Status: String, Codable { case pending, completed }
    public let requestID: String
    public let scope: DataDeletionScope
    public let status: Status
    public let requestedAt: Int64
    public let expectedBy: Int64
    public let completedAt: Int64?
    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", scope, status, requestedAt = "requested_at", expectedBy = "expected_by", completedAt = "completed_at"
    }
    public init(requestID: String, scope: DataDeletionScope, status: Status, requestedAt: Int64, expectedBy: Int64, completedAt: Int64? = nil) {
        self.requestID = requestID; self.scope = scope; self.status = status
        self.requestedAt = requestedAt; self.expectedBy = expectedBy; self.completedAt = completedAt
    }
    public func validate() throws {
        guard requestID.count == 32, requestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              requestedAt > 0, requestedAt <= 4_102_444_800, expectedBy >= requestedAt, expectedBy - requestedAt <= 30 * 86400,
              (status == .pending && completedAt == nil) || (status == .completed && (completedAt ?? 0) >= requestedAt && (completedAt ?? Int64.max) <= 4_102_444_800) else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}
/// Receipt precedes the HTTP request in protected storage. A lost response is
/// checked/retried under the SAME id, never a new account-deletion request.
public struct DataDeletionReceipt: Codable, Equatable {
    public let id: String
    public let token: String
    public let scope: DataDeletionScope
    public var result: DataDeletionResult?
    public init(scope: DataDeletionScope) {
        id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        token = GuestCrypto.randomBytes(count: 32).map { String(format: "%02x", $0) }.joined(); self.scope = scope
    }
    public func validate() throws {
        guard id.count == 32, token.count == 64, (id + token).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GuestCrypto.Failure.invalidEnvelope }
        if let result { try result.validate(); guard result.requestID == id, result.scope == scope else { throw GuestCrypto.Failure.invalidEnvelope } }
    }
}
