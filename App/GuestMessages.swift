import Foundation
import EntrixyCore

enum MessageTarget: Codable, Equatable {
    case owner(server: String, keyID: UUID)
    case passed(UUID)
}
struct SavedMessage: Codable, Identifiable {
    let guestID: String
    let cipher: String
    let receivedAt: Date
    var readAt: Date?
    var deliveryAcknowledged = false
    var readAcknowledged = false
    var delegationWelcomeGroup: String? = nil
    var id: String { guestID + ":" + GuestCrypto.hash(Data(cipher.utf8)) }
    func validate() throws {
        guard !guestID.isEmpty, !cipher.isEmpty, cipher.utf8.count <= (delegationWelcomeGroup == nil ? 4096 : 16384),
              delegationWelcomeGroup.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              readAt?.timeIntervalSinceReferenceDate.isFinite != false,
              !readAcknowledged || readAt != nil else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}
struct OutgoingMessage: Codable, Identifiable {
    enum State: String, Codable { case sending, accepted, uncertain }
    let id: UUID
    let target: MessageTarget
    let text: String
    let cipher: String
    let created: Date
    var state: State
    func validate() throws {
        try GuestMessageCrypto.validateText(text)
        guard !cipher.isEmpty, cipher.utf8.count <= 4096, created.timeIntervalSinceReferenceDate.isFinite else { throw GuestCrypto.Failure.invalidEnvelope }
    }
}
