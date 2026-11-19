import XCTest
import Security
import EntrixyCore
@testable import Entrixy

private final class RecordingController: GuestActionTransport {
    var sent: [Data] = []
    var closed = false
    func sendAction(_ frame: Data) async throws { sent.append(frame) }
    func close() { closed = true }
}

final class ActionFlowTests: XCTestCase {
    private let service = "com.entrixy.ios.action-tests." + UUID().uuidString
    override func tearDown() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        super.tearDown()
    }
    @MainActor private func fixture(template: [String: Any] = [:],imported: AndroidIncomingAutomation? = nil) async throws -> (AppModel, RecordingController, SavedGuest, GuestObject) {
        let invite = try GuestInvite.parse("https://example.invalid/key#AAECAwQFBgcICQoLDA0ODxAREhMUFRYX" + String(repeating: "A", count: 43))
        let guest = SavedGuest(invite:invite,androidAutomation:imported.map { ["7":$0] })
        let store = KeychainStore(service: service)
        try store.save(SavedState(identity: Data(repeating: 53, count: 32), guests: [guest]))
        let model = AppModel(storage: store)
        let key = Data(repeating: 8, count: 32)
        let bundle: [String: Any] = ["obj_keys": ["7": GuestCrypto.base64URL(key)], "templates": ["7": template],
            "sock": ["7": ["guest_id": 513, "token": Data([1, 2, 1]).base64EncodedString(),
                "sig": Data(repeating: 4, count: 16).base64EncodedString(), "gkey": Data(0..<32).base64EncodedString()]]]
        let cipher = try GuestCrypto.encrypt(key: key, plaintext: JSONSerialization.data(withJSONObject: ["label": "Тестовый контроллер"]))
        let snapshot = try JSONSerialization.data(withJSONObject: ["type": "guest_ok", "mode": "on", "numbers": [["id": 7, "type": "device", "device_id": 9, "data_cipher": cipher]]])
        let controller = RecordingController()
        try model.attachTestController(controller, guestID: guest.id, bundle: JSONSerialization.data(withJSONObject: bundle), snapshot: snapshot)
        try await model.receiveTestController(Data(#"{"type":"devices_online","device_ids":[9]}"#.utf8), guestID: guest.id)
        return (model, controller, guest, try XCTUnwrap(model.guests.first?.objects.first))
    }
    @MainActor func testImportedAndroidPINChoiceIsAppliedOnlyAfterFreshBundleAndPersistsWithoutSending() async throws {
        let local = try AutomationTemplate(data:Data(#"{"auth_on":true,"auth":"pin"}"#.utf8))
        let seed = try AndroidIncomingAutomation(local:local,previousOwner:AutomationTemplate())
        let (model,controller,guest,object) = try await fixture(template:["auth_l":"suggest"],imported:seed)
        defer { model.suspend() }
        let intent = try XCTUnwrap(model.actionIntent(guestID:guest.id,object:object))
        XCTAssertEqual(intent.policy.authentication,"pin")
        XCTAssertTrue(model.guests[0].androidAutomation?.isEmpty == true)
        await model.execute(intent)
        XCTAssertTrue(controller.sent.isEmpty); XCTAssertTrue(model.journal.isEmpty)
        let saved = try XCTUnwrap(KeychainStore(service:service).load()?.guests.first)
        XCTAssertEqual(saved.automation?[object.id]?.effective.authMode,"pin"); XCTAssertEqual(saved.invite,guest.invite)
    }
    @MainActor func testPendingCardConfirmationIsDiscardedOnBackgroundWithoutSendingOrPersistingIt() async throws {
        let (model,controller,guest,object) = try await fixture(template:["confirm_on":true])
        let intent = try XCTUnwrap(model.actionIntent(guestID:guest.id,object:object))
        model.actionPrompt = .guest(intent)
        XCTAssertEqual(model.actionPrompt?.id,intent.id)
        XCTAssertTrue(controller.sent.isEmpty); XCTAssertTrue(model.journal.isEmpty)
        model.suspend()
        XCTAssertNil(model.actionPrompt)
        await model.execute(intent)
        XCTAssertTrue(controller.sent.isEmpty); XCTAssertTrue(model.journal.isEmpty)
        let relaunched = AppModel(storage:KeychainStore(service:service))
        XCTAssertNil(relaunched.actionPrompt); XCTAssertTrue(relaunched.journal.isEmpty)
        relaunched.suspend()
    }
    @MainActor func testAutomaticGuestConfirmationAndPINWaitForApprovalAndKeepChallengeBoundToOneArrival() async throws {
        for gate in ["confirm","pin"] {
            var template = AutomationTemplate()
            template.geoEnabled = true; template.geoMode = "route"; template.geoLat = 0; template.geoLon = 0
            template.corridors = [[AutomationGeoPoint(lat:160/111320,lon:0),AutomationGeoPoint(lat:0,lon:0)]]
            template.confirmEnabled = gate == "confirm"; template.authEnabled = gate == "pin"
            template.authMode = gate == "pin" ? "pin" : nil
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with:template.data()) as? [String:Any])
            let (model,controller,guest,object) = try await fixture(template:wire)
            // Runtime evaluates the received three-way result, including owner
            // bounds added by the merge, not the unmerged wire template.
            template = try model.automationContext(.object(.received(guestID:guest.id,objectID:object.id))).template
            XCTAssertTrue(template.geoEnabled)
            XCTAssertEqual(template.confirmEnabled,gate == "confirm")
            XCTAssertEqual(template.authEnabled,gate == "pin")
            if gate == "pin" { try await model.setActionCode("1234") }
            let now = Date()
            var runtime = AutomationRuntime(sessionStarted:now.timeIntervalSince1970-60)
            var proof: AutomationReadiness?
            for (i,distance) in [120.0,90,60,40,20].enumerated() {
                let time = now.addingTimeInterval(Double(i*10-40))
                runtime.receive(AutomationLocationFix(latitude:distance/111320,longitude:0,accuracyM:5,timestampMS:Int64(time.timeIntervalSince1970*1000)))
                proof = runtime.evaluate(key:"route",template:template,date:time)
            }
            let evidence = try XCTUnwrap(proof); XCTAssertTrue(evidence.ready)
            await model.performAutomaticAction(.received(model.guests[0],object),readiness:evidence)
            let prompt = try XCTUnwrap(model.actionPrompt)
            guard case .guest(let intent) = prompt else { return XCTFail("Wrong prompt scope") }
            await model.execute(intent)
            XCTAssertTrue(controller.sent.isEmpty); XCTAssertTrue(model.journal.isEmpty)
            if gate == "pin" {
                let wrong = try await model.authorizeCode("0000",intent:intent)
                XCTAssertFalse(wrong); XCTAssertTrue(controller.sent.isEmpty)
                let correct = try await model.authorizeCode("1234",intent:intent)
                XCTAssertTrue(correct)
            }
            await model.executeActionPrompt(prompt)
            await model.executeActionPrompt(prompt)
            XCTAssertNil(model.actionPrompt); XCTAssertTrue(model.automaticPermits.isEmpty)
            XCTAssertEqual(controller.sent.count,1); XCTAssertEqual(model.journal.count,1)
            XCTAssertEqual(model.journal.first?.who,ProductText.string("journal_who_geo"))
            let challenge = try JSONSerialization.data(withJSONObject:["type":"sock_challenge","number_id":7,"command_id":"gated-"+gate,"nonce":Data(0..<16).base64EncodedString()])
            try await model.receiveTestController(challenge,guestID:guest.id)
            try await model.receiveTestController(challenge,guestID:guest.id)
            XCTAssertEqual(controller.sent.count,2)
            model.suspend()
        }
    }
    @MainActor func testPressChallengeResultAndJournalSurviveRelaunchWithoutReplay() async throws {
        let (model, controller, guest, object) = try await fixture()
        let challenge = try JSONSerialization.data(withJSONObject: ["type": "sock_challenge", "number_id": 7, "command_id": "test-1", "nonce": Data(0..<16).base64EncodedString()])
        try await model.receiveTestController(challenge, guestID: guest.id)
        XCTAssertTrue(controller.sent.isEmpty)
        let intent = try XCTUnwrap(model.actionIntent(guestID: guest.id, object: object))
        await model.execute(intent)
        XCTAssertEqual(controller.sent.count, 1)
        XCTAssertEqual(try KeychainStore(service: service).load()?.journal?.count, 1)
        XCTAssertNil(model.actionIntent(guestID: guest.id, object: object))
        try await model.receiveTestController(challenge, guestID: guest.id)
        XCTAssertEqual(controller.sent.count, 2)
        try await model.receiveTestController(challenge, guestID: guest.id)
        XCTAssertEqual(controller.sent.count, 2)
        try await model.receiveTestController(Data(#"{"type":"device_status","number_id":7,"message":"Opened","level":"success"}"#.utf8), guestID: guest.id)
        XCTAssertEqual(model.journal.first?.result, "Opened")
        try await model.receiveTestController(Data(#"{"type":"device_status","number_id":7,"message":"Other action","other":true}"#.utf8), guestID: guest.id)
        XCTAssertEqual(model.journal.first?.result, "Opened")
        model.suspend()
        XCTAssertEqual(model.actionMessages[guest.id + "|" + object.id], "Opened")
        XCTAssertTrue(controller.closed)
        try await model.receiveTestController(challenge, guestID: guest.id)
        XCTAssertEqual(controller.sent.count, 2)
        let restored = AppModel(storage: KeychainStore(service: service))
        XCTAssertEqual(restored.journal.first?.result, "Opened")
        XCTAssertEqual(controller.sent.count, 2)
        // Clearing the journal during another attempt must not swallow its result.
        let (clearing, secondController, secondGuest, secondObject) = try await fixture()
        let secondIntent = try XCTUnwrap(clearing.actionIntent(guestID: secondGuest.id, object: secondObject))
        await clearing.execute(secondIntent)
        clearing.clearJournal()
        try await clearing.receiveTestController(Data(#"{"type":"device_status","number_id":7,"message":"Opened","level":"success"}"#.utf8), guestID: secondGuest.id)
        XCTAssertEqual(clearing.actionMessages[secondGuest.id + "|" + secondObject.id], "Opened")
        XCTAssertTrue(clearing.journal.isEmpty)
        XCTAssertEqual(secondController.sent.count, 1)
        clearing.suspend()
    }
    @MainActor func testOfflineOrChangedAuthorizationCannotSend() async throws {
        let (model, controller, guest, object) = try await fixture()
        let intent = try XCTUnwrap(model.actionIntent(guestID: guest.id, object: object))
        try await model.receiveTestController(Data(#"{"type":"device_online","device_id":9,"online":false}"#.utf8), guestID: guest.id)
        await model.execute(intent)
        XCTAssertTrue(controller.sent.isEmpty)
        XCTAssertTrue(model.journal.isEmpty)
        XCTAssertNil(model.actionIntent(guestID: guest.id, object: object))
        XCTAssertNil(model.errorMessage, "Unavailable card taps must not open the global alert")
        let key = guest.id + "|" + object.id
        let rejection = try XCTUnwrap(model.actionRejections[key])
        XCTAssertEqual(rejection.message, "Контроллер не в сети.")
        XCTAssertNil(model.actionIntent(guestID: guest.id, object: object))
        XCTAssertNotEqual(model.actionRejections[key]?.id, rejection.id, "Each rejected tap needs fresh feedback")
        XCTAssertTrue(controller.sent.isEmpty)
        XCTAssertTrue(model.journal.isEmpty)
        try await model.receiveTestController(Data(#"{"type":"device_online","device_id":9,"online":true}"#.utf8), guestID: guest.id)
        XCTAssertNotNil(model.actionIntent(guestID: guest.id, object: object))
        XCTAssertNil(model.actionRejections[key])
        XCTAssertTrue(controller.sent.isEmpty, "Recovery does not retry a physical command")
        model.suspend()
    }
    @MainActor func testVisibleActionNameFollowsControllerDirectionWithoutSendingOrChangingErrors() async throws {
        let (model, controller, guest, object) = try await fixture()
        XCTAssertEqual(model.objectActionTitle(guestID: guest.id, object: object), "Открыть")
        XCTAssertEqual(model.actionIntent(guestID: guest.id, object: object)?.title, "Открыть")
        try await model.receiveTestController(Data(#"{"type":"obj_state_update","num_id":7,"position":"open"}"#.utf8), guestID: guest.id)
        XCTAssertEqual(model.objectPosition(.received(guest,object)),"open")
        model.errorMessage = "existing notice"
        for _ in 0..<20 { XCTAssertEqual(model.objectActionTitle(guestID: guest.id, object: object), "Закрыть") }
        XCTAssertEqual(model.errorMessage, "existing notice")
        XCTAssertTrue(controller.sent.isEmpty)
        XCTAssertTrue(model.journal.isEmpty)
        let intent = try XCTUnwrap(model.actionIntent(guestID: guest.id, object: object))
        XCTAssertEqual(intent.title, "Закрыть")
        await model.execute(intent)
        let packet = try XCTUnwrap(controller.sent.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: packet) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "close")
        model.suspend()
    }

    @MainActor func testPINIsRequiredAndFailedAttemptsPersistAcrossLaunches() async throws {
        let (model, controller, guest, object) = try await fixture(template: ["auth_on": true, "auth": "pin"])
        try await model.setActionCode("1234")
        let intent = try XCTUnwrap(model.actionIntent(guestID: guest.id, object: object))
        await model.execute(intent)
        XCTAssertTrue(controller.sent.isEmpty)
        let accepted = try await model.authorizeCode("1234", intent: intent)
        XCTAssertTrue(accepted)
        await model.execute(intent)
        XCTAssertEqual(controller.sent.count, 1)
        model.suspend()
        let restored = AppModel(storage: KeychainStore(service: service))
        XCTAssertTrue(restored.hasActionCode)
        for _ in 0..<5 {
            let accepted = try await restored.authorizeCode("0000", intent: intent)
            XCTAssertFalse(accepted)
        }
        let saved = try XCTUnwrap(KeychainStore(service: service).load()?.actionCode)
        XCTAssertEqual(saved.failures, 5)
        XCTAssertGreaterThan(saved.lockedUntil, Date())
        let blocked = try await restored.authorizeCode("1234", intent: intent)
        XCTAssertFalse(blocked)
    }
    func testPINUsesIndependentPBKDF2VectorAndEscalatingLockout() throws {
        let hash = try LocalActionCode.derive("1234", salt: Data(0..<16))
        XCTAssertEqual(hash.map { String(format: "%02x", $0) }.joined(), "4377fadf9b31b873d27e134c959c727ab5015df85137afdd552ba717e092ccf4")
        var code = LocalActionCode(salt: Data(0..<16), verifier: hash)
        for _ in 0..<4 { code.failed() }
        XCTAssertLessThan(code.lockedUntil, Date())
        code.failed()
        XCTAssertGreaterThan(code.lockedUntil.timeIntervalSinceNow, 25)
        for _ in 0..<5 { code.failed() }
        XCTAssertGreaterThan(code.lockedUntil.timeIntervalSinceNow, 7100)
        XCTAssertThrowsError(try LocalActionCode.derive("x123", salt: code.salt))
    }
}
