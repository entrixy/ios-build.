import Foundation
import XCTest
@testable import EntrixyCore

final class PassedAccessTests: XCTestCase {
    private let group = String(repeating: "B", count: 22), code = String(repeating: "C", count: 22)
    private func invite() throws -> GuestInvite { try GuestInvite.parse("https://sender.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43)) }
    private func snapshot(invites: [[String: Any]] = [], children: [[String: Any]] = []) throws -> PassSnapshot {
        try PassSnapshot.decode(JSONSerialization.data(withJSONObject: ["objects": [["id": 7, "depth": 2, "pool_left": 8, "native_only": 0]], "invites": invites, "children": children]))
    }
    private func part(group: String? = nil) throws -> [String: Any] {
        ["code": code, "grp": group ?? self.group, "status": "new", "objects": [try KeyObjectAccess(depth: 0, pool: 1).json(id: 7)]]
    }
    private func record() throws -> PassedAccess {
        let source = try invite()
        return try PassedAccess(server: source.server, label: "Получатель", welcome: "private greeting", objects: [source.id: [7: KeyObjectAccess(depth: 0, pool: 1)]], snapshots: [source.id: snapshot()])
    }
    func testLostCreateReplyRecoversOneNewMatchingInviteAndPreservesSecretAcrossRelaunch() throws {
        let source = try invite()
        var record = try record()
        XCTAssertThrowsError(try record.createRequest(part: 0))
        record.parts[0].sent = true
        let body = String(decoding: try record.createRequest(part: 0), as: UTF8.self)
        XCTAssertFalse(body.contains("private greeting"))
        XCTAssertFalse(body.contains(GuestCrypto.base64URL(record.secret)))
        record = try JSONDecoder().decode(PassedAccess.self, from: JSONEncoder().encode(record))
        let secret = record.secret
        XCTAssertNil(record.link)
        try record.reconcile(snapshot(invites: [part()]), sourceID: source.id)
        XCTAssertEqual(record.secret, secret)
        XCTAssertEqual(record.parts[0].state, .available)
        XCTAssertEqual(record.link?.group, group)
        XCTAssertEqual(try DelegationLink.parse(record.link!.url).secret, secret)
        let request = try JSONSerialization.jsonObject(with: record.createRequestAfterResettingState()) as! [String: Any]
        XCTAssertEqual(request["grp"] as? String, group)
        XCTAssertNil(request["welcome_cipher"])
    }
    func testAmbiguousInitialReplyNeverPicksAnArbitraryGroup() throws {
        let source = try invite()
        var record = try record(); record.parts[0].sent = true
        XCTAssertThrowsError(try record.reconcile(snapshot(invites: [part(), part(group: String(repeating: "D", count: 22))]), sourceID: source.id))
        XCTAssertNil(record.group)
        XCTAssertNil(record.link)
    }
    func testRecipientProofMustMatchBeforeParentVouchAndObjectMismatchBlocksIt() throws {
        let source = try invite()
        var record = try record(); record.parts[0].sent = true
        try record.reconcile(snapshot(invites: [part()]), sourceID: source.id)
        let recipient = BundleKeySeal.makeRecipient(), sp = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3").publicKey.rawRepresentation)
        var child: [String: Any] = ["id": 18, "grp": group, "number_ids": [7], "objects": [try KeyObjectAccess(depth: 0, pool: 1).json(id: 7)], "sign_pub": sp, "guest_pub": recipient.publicKey, "vouched": 0, "ready": 0]
        child["pass_mac"] = try DelegationProof.passMAC(secret: record.secret, group: group, signPublic: sp, guestPublic: recipient.publicKey)
        var snapshot = try snapshot(invites: [part()], children: [child])
        try record.reconcile(snapshot, sourceID: source.id)
        let requests = try record.vouches(snapshot: snapshot, invite: source)
        XCTAssertEqual(requests.count, 1)
        let json = try JSONSerialization.jsonObject(with: requests[0]) as! [String: Any]
        XCTAssertTrue(try DelegationProof.verifyVouch(json["sig"] as! String,
            parentPublic: GuestCrypto.signingKey(userKey: source.userKey).publicKey.rawRepresentation,
            server: source.server, childID: 18, signPublic: sp, guestPublic: recipient.publicKey))
        child["pass_mac"] = String(repeating: "0", count: 64)
        snapshot = try self.snapshot(invites: [part()], children: [child])
        XCTAssertTrue(try record.vouches(snapshot: snapshot, invite: source).isEmpty)
        child["objects"] = [try KeyObjectAccess().json(id: 8)]; child["number_ids"] = [8]
        snapshot = try self.snapshot(invites: [part()], children: [child])
        try record.reconcile(snapshot, sourceID: source.id)
        XCTAssertEqual(record.parts[0].state, .unavailable)
        XCTAssertNil(record.link)
        XCTAssertTrue(try record.vouches(snapshot: snapshot, invite: source).isEmpty)
    }
    func testSnapshotAndRequestedLimitsAreStrict() throws {
        let source = try invite(), snapshot = try snapshot()
        XCTAssertThrowsError(try PassedAccess(server: source.server, label: "", welcome: "", objects: [source.id: [7: KeyObjectAccess()]], snapshots: [source.id: snapshot]))
        XCTAssertThrowsError(try PassedAccess(server: source.server, label: "Имя", welcome: "", objects: [source.id: [7: KeyObjectAccess(depth: 2)]], snapshots: [source.id: snapshot]))
        for value: Any in [true, -1, 2.5] {
            let bytes = try JSONSerialization.data(withJSONObject: ["objects": [["id": 7, "depth": value, "pool_left": 8, "native_only": 0]], "invites": [], "children": []])
            XCTAssertThrowsError(try PassSnapshot.decode(bytes))
        }
    }
    func testObjectEditDoesNotEnableSharingOrVouchUntilExactScopeIsConfirmed() throws {
        let source = try invite()
        var record = try record(); record.parts[0].sent = true
        try record.reconcile(snapshot(invites: [part()]), sourceID: source.id)
        let recipient = BundleKeySeal.makeRecipient(), pub = GuestCrypto.base64URL(try GuestCrypto.signingKey(userKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3").publicKey.rawRepresentation)
        var child: [String: Any] = ["id": 18, "grp": group, "number_ids": [7], "objects": [try KeyObjectAccess(depth: 0, pool: 1).json(id: 7)],
            "sign_pub": pub, "guest_pub": recipient.publicKey, "vouched": 0, "ready": 1]
        child["pass_mac"] = try DelegationProof.passMAC(secret: record.secret, group: group, signPublic: pub, guestPublic: recipient.publicKey)
        let old = try snapshot(invites: [part()], children: [child])
        try record.reconcile(old, sourceID: source.id)
        let desired = ["7": try KeyObjectAccess(depth: 0, pool: 1), "8": try KeyObjectAccess(depth: 0, pool: 1)]
        record.parts[0].pendingEdit = desired; record.parts[0].editSent = true
        try record.reconcile(old, sourceID: source.id)
        XCTAssertNotNil(record.parts[0].pendingEdit)
        XCTAssertNil(record.link)
        XCTAssertTrue(try record.vouches(snapshot: old, invite: source).isEmpty)
        child["objects"] = desired.keys.sorted().map { desired[$0]!.json(id: Int($0)!) }; child["number_ids"] = [7,8]; child["ready"] = 0
        try record.reconcile(snapshot(invites: [part()], children: [child]), sourceID: source.id)
        XCTAssertNil(record.parts[0].pendingEdit)
        XCTAssertEqual(record.parts[0].objects, desired)
        XCTAssertEqual(record.parts[0].state, .awaitingOwner)
        XCTAssertNotNil(record.link)
    }
    func testKnownGroupDoesNotTurnUnsentSecondPartIntoAnUnknownRequest() throws {
        let first = try invite(), second = try GuestInvite.parse("https://sender.invalid/key#ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3" + String(repeating: "A", count: 43))
        var record = try PassedAccess(server: first.server, label: "Получатель", welcome: "",
            objects: [first.id: [7: KeyObjectAccess(depth: 0, pool: 1)], second.id: [7: KeyObjectAccess(depth: 0, pool: 1)]], snapshots: [first.id: snapshot(), second.id: snapshot()])
        let initialID = record.parts[0].sourceID, nextID = record.parts[1].sourceID
        record.parts[0].sent = true
        try record.reconcile(snapshot(invites: [part()]), sourceID: initialID)
        try record.reconcile(snapshot(), sourceID: nextID)
        XCTAssertEqual(record.parts[1].state, .draft)
        XCTAssertFalse(record.parts[1].sent)
        XCTAssertNil(record.link)
    }
}
private extension PassedAccess {
    func createRequestAfterResettingState() throws -> Data { var copy = self; copy.parts[0].state = .draft; return try copy.createRequest(part: 0) }
}
