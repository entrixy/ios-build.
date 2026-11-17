import XCTest
@testable import EntrixyCore

final class AndroidIncomingAutomationTests: XCTestCase {
    private func document(_ additional: [String:String]) throws -> AndroidBackupDocument {
        var values = additional
        values["backup_src_seed"] = String(repeating:"ab",count:32)
        values["guest_keys"] = #"[{"id":3,"host":"first.invalid","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"},{"id":30,"host":"second.invalid","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"}]"#
        let entries = values.mapValues { ["t":"s","v":$0] }
        return try AndroidBackupDocument(JSONSerialization.data(withJSONObject:["app":"entrixy","ver":1,"created":1_800_000_000,"device":"Public fixture","count":entries.count,"entries":entries]))
    }
    func testLocalChoicesAndPreviousOwnerStayScopedToExactKeyAndFollowFreshBounds() throws {
        let source = try document(["e2ee_in_tpl_3_7":#"{"auth_on":true,"auth":"pin","confirm_on":true,"confirm":true}"#,"e2ee_in_tplo_3_7":"{}","e2ee_in_tpl_30_7":"{}"])
        let rules = try source.incomingAutomation(localID:3), other = try source.incomingAutomation(localID:30)
        XCTAssertEqual(rules.count,1); XCTAssertTrue(try XCTUnwrap(rules["7"]).local.authEnabled)
        XCTAssertFalse(try XCTUnwrap(other["7"]).local.authEnabled)
        let fresh = try AutomationTemplate(data:Data(#"{"auth_l":"suggest","confirm_l":"suggest"}"#.utf8))
        let merged = try XCTUnwrap(rules["7"]).receiving(fresh)
        XCTAssertTrue(merged.effective.authEnabled); XCTAssertEqual(merged.effective.authMode,"pin"); XCTAssertEqual(merged.effective.requireConfirmation,true)
        let force = try AutomationTemplate(data:Data(#"{"auth_on":true,"auth":"biometric","auth_l":"force","confirm_on":true,"confirm":true,"confirm_l":"force"}"#.utf8))
        let constrained = try XCTUnwrap(rules["7"]).receiving(force)
        XCTAssertEqual(constrained.effective.authMode,"biometric"); XCTAssertTrue(constrained.effective.authEnabled)
    }
    func testMissingPreviousOwnerUsesAndroidFirstMergeRatherThanFabricatingOwnerHistory() throws {
        let source = try document(["e2ee_in_tpl_3_7":#"{"auth_on":true,"auth":"pin"}"#])
        let rule = try XCTUnwrap(source.incomingAutomation(localID:3)["7"])
        XCTAssertNil(rule.previousOwner)
        let merged = try rule.receiving(AutomationTemplate())
        XCTAssertFalse(merged.effective.authEnabled)
        let again = try JSONDecoder().decode(AndroidIncomingAutomation.self,from:JSONEncoder().encode(rule)); XCTAssertEqual(again,rule)
    }
    func testMalformedObjectKeyAndTemplateOrAnotherGuestCannotBeAdopted() throws {
        XCTAssertThrowsError(try document(["e2ee_in_tpl_3_../7":"{}"]).incomingAutomation(localID:3))
        XCTAssertThrowsError(try document(["e2ee_in_tpl_3_7":#"{"auth":"unsupported"}"#]).incomingAutomation(localID:3))
        XCTAssertThrowsError(try document([:]).incomingAutomation(localID:4))
    }
}
