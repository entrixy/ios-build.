import Foundation
import XCTest
@testable import EntrixyCore

final class DelegationEndToEndTests: XCTestCase {
    func testSenderRecipientAndOwnerCompleteTheProtocolWithoutSharingPrivateMaterial() throws {
        var owner = try OwnerAccount(server: "controller.invalid")
        var object = try OwnerObject(masterKey: owner.masterKey, label: "Ворота во двор", kind: "webhook", url: "https://actuator.invalid/open", secret: "owner-only-secret")
        object.numberID = 7; object.pending = nil; object.revision = 100; object.available = true; owner.objects = [object]
        var root = try OwnerIssuedKey(owner: owner, label: "Передающий", numberIDs: [7], welcome: "", nativeOnly: false, confirmation: true, access: [7: KeyObjectAccess(depth: 2, pool: 8)])
        root.keyID = 17; root.pending = nil; root.state = .active; root.effectiveNumberIDs = [7]; root.access = root.grantedAccess; root.requestedAccess = nil
        owner.issuedKeys = [root]
        let source = try GuestInvite.parse(root.link(server: owner.server, masterKey: owner.masterKey).absoluteString)
        let settings = try KeyObjectAccess(depth: 0, pool: 1)
        let allow = [["id": 7, "depth": 2, "pool_left": 8, "native_only": 0]]
        func passSnapshot(invites: [[String: Any]], children: [[String: Any]]) throws -> PassSnapshot {
            try PassSnapshot.decode(JSONSerialization.data(withJSONObject: ["objects": allow, "invites": invites, "children": children]))
        }
        var sender = try PassedAccess(server: owner.server, label: "Получатель", welcome: "Добро пожаловать", objects: [source.id: [7: settings]], snapshots: [source.id: passSnapshot(invites: [], children: [])])
        sender.parts[0].sent = true
        let group = String(repeating: "D", count: 22), code = String(repeating: "C", count: 22)
        try sender.acceptCreateReply(JSONSerialization.data(withJSONObject: ["grp": group, "code": code]), part: 0)
        var invitation: [String: Any] = ["code": code, "grp": group, "status": "new", "objects": [settings.json(id: 7)]]
        try sender.reconcile(passSnapshot(invites: [invitation], children: []), sourceID: source.id)
        let link = try XCTUnwrap(sender.link)
        let info = try JSONSerialization.data(withJSONObject: ["grp": group, "state": "new", "parts": [["code": code, "state": "new"]]])
        var recipient = try DelegationRedemption(link: DelegationLink.parse(link.url), info: info)
        recipient.sent = true
        let redeem = try recipient.request(fingerprint: String(repeating: "a", count: 64))
        let redeemJSON = try JSONSerialization.jsonObject(with: redeem) as! [String: Any]
        let part = (redeemJSON["parts"] as! [[String: Any]])[0]
        let pub = part["sign_pub"] as! String, guestPub = redeemJSON["guest_pub"] as! String
        invitation["status"] = "redeemed"
        let child: [String: Any] = ["id": 18, "grp": group, "number_ids": [7], "ble_ids": [Int](), "objects": [settings.json(id: 7)],
            "sign_pub": pub, "guest_pub": guestPub, "pass_mac": part["mac"]!, "vouched": 0, "ready": 0]
        let snapshot = try passSnapshot(invites: [invitation], children: [child])
        try sender.reconcile(snapshot, sourceID: source.id)
        let vouches = try sender.vouches(snapshot: snapshot, invite: source)
        let vouch = try JSONSerialization.jsonObject(with: XCTUnwrap(vouches.first)) as! [String: Any]
        let ownerRow: [String: Any] = ["id": 18, "parent_key_id": 17, "enabled": 1, "mode": "auto", "number_ids": [7], "ble_ids": [Int](),
            "objects": [settings.json(id: 7)], "sign_pub": pub, "guest_pub": guestPub, "vouch_sig": vouch["sig"]!, "needs_bundle": 1]
        let ownerSnapshot = try OwnerSnapshot.decode(JSONSerialization.data(withJSONObject: ["numbers": [], "keys": [ownerRow]]))
        XCTAssertEqual(try owner.reconcileDelegatedKeys(ownerSnapshot), 0)
        var issued = try XCTUnwrap(owner.delegatedKeys?.first)
        issued.sent = true
        let upload = try issued.request()
        let received = try recipient.invitation(part: recipient.parts[0], keyCipher: issued.keyCipher)
        let bundle = try GuestCrypto.decrypt(key: received.bundleKey, envelope: issued.bundleCipher)
        let objects = try GuestObjects.decode(bundle: bundle, snapshot: JSONSerialization.data(withJSONObject: ["numbers": [["id": 7, "type": "webhook", "data_cipher": object.cipher]]]))
        XCTAssertEqual(objects.map(\.label), ["Ворота во двор"])
        XCTAssertEqual(received.userKey, recipient.parts[0].userKey)
        XCTAssertNotEqual(received.userKey, source.userKey)
        let headersOnly = [try sender.createRequestAfterSent(), redeem, upload, vouches[0]]
        for bytes in headersOnly {
            let text = String(decoding: bytes, as: UTF8.self)
            for secret in [source.userKey, GuestCrypto.base64URL(sender.secret), recipient.recipient.privateKey, recipient.parts[0].userKey,
                           GuestCrypto.base64URL(owner.masterKey), GuestCrypto.base64URL(received.bundleKey), "owner-only-secret"] {
                XCTAssertFalse(text.contains(secret))
            }
        }
    }
}
private extension PassedAccess {
    func createRequestAfterSent() throws -> Data { var copy = self; copy.parts[0].state = .draft; return try copy.createRequest(part: 0) }
}
