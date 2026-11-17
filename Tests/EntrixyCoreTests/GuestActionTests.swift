import XCTest
@testable import EntrixyCore

final class GuestActionTests: XCTestCase {
    private func credential() throws -> SocketCredential {
        try SocketCredential(json: ["guest_id": 513, "token": Data([1, 2, 1]).base64EncodedString(),
            "sig": Data(repeating: 4, count: 16).base64EncodedString(),
            "gkey": Data(0..<32).base64EncodedString()])
    }
    private var challenge: [String: Any] {
        ["type": "sock_challenge", "number_id": 7, "command_id": "fake-controller-1",
         "nonce": Data(0..<16).base64EncodedString()]
    }
    func testFakeControllerAcceptsOnlyMatchingSingleUseIntentAndDirection() throws {
        // Independent Python hmac/hashlib vectors, also matching the ESP nonce16 contract.
        for (action, expected) in [(GuestAction.open, "d8b99f2709a3ca74172cbe93824c1f29"),
                                    (.close, "74f10ae9d6aae599467fbef0ec94f3a8")] {
            var session = GuestActionSession()
            XCTAssertThrowsError(try session.fire(challenge: challenge, now: 100))
            try session.begin(numberID: 7, action: action, credential: credential(), now: 100)
            var wrong = challenge; wrong["number_id"] = 8
            XCTAssertThrowsError(try session.fire(challenge: wrong, now: 101))
            wrong = challenge; wrong["nonce"] = Data(repeating: 0, count: 8).base64EncodedString()
            XCTAssertThrowsError(try session.fire(challenge: wrong, now: 101))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: session.fire(challenge: challenge, now: 101)) as? [String: Any])
            let proof = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["proof"] as? String)))
            XCTAssertEqual(proof.map { String(format: "%02x", $0) }.joined(), expected)
            XCTAssertEqual(body["action"] as? String, action == .close ? "close" : nil)
            XCTAssertEqual(body["number_id"] as? Int, 7)
            XCTAssertThrowsError(try session.fire(challenge: challenge, now: 102))
            XCTAssertThrowsError(try session.begin(numberID: 8, action: .open, credential: credential(), now: 102))
            // Disconnect/background means replacing the session; old challenge loses authority.
            var reconnected = GuestActionSession()
            XCTAssertThrowsError(try reconnected.fire(challenge: challenge, now: 103))
        }
    }
    func testExpiredIntentAndMissingCredentialNeverProduceFire() throws {
        var session = GuestActionSession()
        try session.begin(numberID: 7, action: .open, credential: credential(), now: 100)
        XCTAssertThrowsError(try session.fire(challenge: challenge, now: 130))
        XCTAssertThrowsError(try session.fire(challenge: challenge, now: 99))
        var unsigned = GuestActionSession()
        try unsigned.begin(numberID: 7, action: .open, credential: nil, now: 100)
        XCTAssertThrowsError(try unsigned.fire(challenge: challenge, now: 101))
        XCTAssertThrowsError(try SocketCredential(json: ["guest_id": 513, "token": Data(repeating: 0, count: 7).base64EncodedString()]))
    }
    func testPressSignsExactAndroidHostNumberAndWireActionWithBaseKey() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "client-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let key = try XCTUnwrap(fixture["userKey"] as? String)
        let publicKey = try GuestCrypto.decodeBase64URL(try XCTUnwrap(fixture["signPubB64"] as? String))
        for action in ["", "close", "toggle", "open"] {
            let nonce = String(repeating: "a", count: 32)
            let data = try GuestPress.frame(userKey: key, host: "https://example.invalid", numberID: 7, wireAction: action, timestamp: 123456, nonce: nonce)
            let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let press = try XCTUnwrap(frame["press"] as? [String: Any])
            let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(press["sig"] as? String)))
            let material = Data("press-v1.https://example.invalid.7.\(action).123456.\(nonce)".utf8)
            XCTAssertTrue(try GuestCrypto.verify(signature: signature, material: material, publicKey: publicKey))
            XCTAssertFalse(try GuestCrypto.verify(signature: signature, material: material + Data("close".utf8), publicKey: publicKey))
            XCTAssertEqual(frame["action"] as? String, action.isEmpty ? nil : action)
        }
    }
    private func policy(template: Any = [String: Any](), metadata: [String: Any] = ["label": "Test"], extra: [String: Any] = [:], overrides: IncomingAutomationConfiguration? = nil, readiness: AutomationReadiness? = nil, date: Date = Date()) throws -> GuestActionPolicy {
        let key = Data(repeating: 9, count: 32)
        var bundle: [String: Any] = ["obj_keys": ["7": GuestCrypto.base64URL(key)], "templates": ["7": template]]
        bundle.merge(extra) { _, new in new }
        let row: [String: Any] = ["id": 7, "type": "webhook", "data_cipher": try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: metadata))]
        return try GuestActionPolicy.decode(bundle: JSONSerialization.data(withJSONObject: bundle),
            snapshot: JSONSerialization.data(withJSONObject: ["numbers": [row]]), numberID: 7, overrides: overrides, readiness: readiness, date: date)
    }
    func testCombinedConditionsNeedFreshMatchingEvidenceAndCannotClearNetworkBan() throws {
        var template = AutomationTemplate()
        template.combineMode = "all"; template.wifiEnabled = true; template.timeEnabled = true
        template.timeEntries = [AutomationTimeEntry(weekdays:[],fromMin:0,toMin:60)]
        var runtime = AutomationRuntime(sessionStarted:99)
        _ = runtime.evaluate(key:"a",template:template,date:Date(timeIntervalSince1970:100),wifiMatches:0,wifiRequired:1)
        var utc = Calendar(identifier:.gregorian); utc.timeZone = TimeZone(secondsFromGMT:0)!
        let date = Date(timeIntervalSince1970:101)
        let proof = runtime.evaluate(key:"a",template:template,date:date,wifiMatches:1,wifiRequired:1,calendar:utc)
        XCTAssertTrue(proof.matched)
        let wire = try JSONSerialization.jsonObject(with:template.data())
        XCTAssertNil(try policy(template:wire,readiness:proof,date:date).blockedReason)
        XCTAssertNil(try OwnerManualPolicy(template.data(),readiness:proof,date:date).blockedReason)
        XCTAssertNotNil(try policy(template:wire,readiness:proof,date:date.addingTimeInterval(3)).blockedReason)
        XCTAssertNotNil(try OwnerManualPolicy(template.data(),readiness:proof,date:date.addingTimeInterval(-1)).blockedReason)
        XCTAssertNotNil(try policy(template:wire,extra:["net_block":["blocked"]],readiness:proof,date:date).blockedReason)
        template.confirmEnabled = true
        XCTAssertNotNil(try policy(template:JSONSerialization.jsonObject(with:template.data()),readiness:proof,date:date).blockedReason)
    }

    func testManualOverrideMatchesAndroidAndUnsupportedHardGatesFailClosed() throws {
        XCTAssertNil(try policy(template: ["mode": "any", "geo_on": true, "wifi_on": true]).blockedReason)
        XCTAssertNil(try policy(template: ["mode": "all", "geo_on": true]).blockedReason)
        XCTAssertNotNil(try policy(template: ["mode": "all", "geo_on": true, "wifi_on": true]).blockedReason)
        XCTAssertNotNil(try policy(extra: ["net_block": ["network"]]).blockedReason)
        XCTAssertThrowsError(try policy(template: ["auth_on": "false"]))
        XCTAssertThrowsError(try policy(template: ["auth_on": true, "auth": "unknown"]))
        XCTAssertThrowsError(try policy(template: "bad template"))
        XCTAssertThrowsError(try policy(extra: ["net_block": "bad restriction"]))
        let protected = try policy(template: ["auth_on": true, "auth": "pin", "confirm_on": true], metadata: ["wh_toggle": 1])
        XCTAssertEqual(protected.authentication, "pin")
        XCTAssertTrue(protected.confirmation)
        XCTAssertTrue(protected.toggles)
    }
    func testTargetDenialIsNotMisclassifiedAsKeyRevocation() throws {
        if case .action = try GuestEvent.decode(Data(#"{"type":"error","reason":"device_offline"}"#.utf8)) {} else { XCTFail() }
        if case .action = try GuestEvent.decode(Data(#"{"type":"error","reason":"disabled","number_id":7}"#.utf8)) {} else { XCTFail() }
        if case .unavailable = try GuestEvent.decode(Data(#"{"type":"error","reason":"disabled"}"#.utf8)) {} else { XCTFail() }
    }
    func testSuggestedLocalAuthenticationIsUsedByRealActionPolicy() throws {
        var owner = AutomationTemplate()
        var local = IncomingAutomationConfiguration(owner: owner)
        var edited = local.effective; edited.authEnabled = true; edited.authMode = "pin"; edited.confirmEnabled = true
        try local.edit(edited)
        let decoded = try policy(template: JSONSerialization.jsonObject(with: owner.data()), overrides: local)
        XCTAssertEqual(decoded.authentication, "pin"); XCTAssertTrue(decoded.confirmation)
        owner.authEnabled = true; owner.authMode = "biometric"; owner.authLevel = .force
        let forced = try policy(template: JSONSerialization.jsonObject(with: owner.data()), overrides: local)
        XCTAssertEqual(forced.authentication, "biometric")
        XCTAssertNotEqual(decoded.template, forced.template)
    }
    func testFreshOwnerForceAllCannotBeRelaxedByOldLocalSnapshot() throws {
        var local = IncomingAutomationConfiguration(owner: AutomationTemplate())
        local.effective.geoEnabled = false; local.effective.wifiEnabled = false
        var fresh = AutomationTemplate(); fresh.combineLevel = .force; fresh.combineMode = "all"
        fresh.geoEnabled = true; fresh.wifiEnabled = true
        let decoded = try policy(template: JSONSerialization.jsonObject(with: fresh.data()), overrides: local)
        XCTAssertNotNil(decoded.blockedReason)
        let effective = try AutomationTemplate(data: decoded.template)
        XCTAssertTrue(effective.geoEnabled); XCTAssertTrue(effective.wifiEnabled)
    }
    func testLocalUnknownFieldsCannotChangeOwnerServerRoutingOrNetworkBan() throws {
        let malicious = try AutomationTemplate(data: Data(#"{"server_webhook":true}"#.utf8))
        var local = IncomingAutomationConfiguration(owner: malicious)
        local.owner = AutomationTemplate()
        let decoded = try policy(template: ["server_webhook": false], extra: ["net_block": ["restricted"]], overrides: local)
        XCTAssertFalse(decoded.serverWebhook); XCTAssertNotNil(decoded.blockedReason)
    }

}
