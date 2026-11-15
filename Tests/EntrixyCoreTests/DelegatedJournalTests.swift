import XCTest
@testable import EntrixyCore

final class DelegatedJournalTests: XCTestCase {
    private let group = String(repeating: "A", count: 22)
    private func snapshot(_ events: Any) throws -> PassSnapshot {
        try PassSnapshot.decode(JSONSerialization.data(withJSONObject: ["objects": [], "invites": [], "children": [], "journal": events]))
    }
    func testServerEventsAreBoundedTypedAndDeduplicatedPerHostAcrossPersistence() throws {
        let event: [String: Any] = ["id": 4, "number_id": 7, "ts": 1000, "grp": group]
        let rows = try snapshot([event]).journal
        XCTAssertEqual(rows.first?.epoch, 1000)
        var ledger = DelegatedJournalLedger()
        XCTAssertEqual(try ledger.accept(rows, server: "one.invalid").count, 1)
        ledger = try JSONDecoder().decode(DelegatedJournalLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertTrue(try ledger.accept(rows, server: "one.invalid").isEmpty)
        XCTAssertEqual(try ledger.accept(rows, server: "two.invalid").count, 1)
        XCTAssertThrowsError(try snapshot([event, event]))
        for field in ["id", "number_id", "ts"] {
            var wrong = event; wrong[field] = true
            XCTAssertThrowsError(try snapshot([wrong]))
        }
        var wrong = event; wrong["ts"] = -1
        XCTAssertThrowsError(try snapshot([wrong]))
        wrong = event; wrong["grp"] = "not-a-group"
        XCTAssertThrowsError(try snapshot([wrong]))
        XCTAssertThrowsError(try snapshot("not-events"))
    }
    func testLedgerMergeRetainsTargetHistoryAndLegacyListHasNoEvents() throws {
        let plain = try JSONSerialization.data(withJSONObject: ["objects": [], "invites": [], "children": []])
        XCTAssertTrue(try PassSnapshot.decode(plain).journal.isEmpty)
        var target = DelegatedJournalLedger(), source = DelegatedJournalLedger()
        let one = DelegatedJournalEvent(id: 1, numberID: 7, group: group, epoch: 1000)
        let two = DelegatedJournalEvent(id: 2, numberID: 7, group: group, epoch: 1001)
        _ = try target.accept([one], server: "one.invalid")
        _ = try source.accept([two], server: "one.invalid")
        try target.merge(source)
        XCTAssertTrue(try target.accept([one, two], server: "one.invalid").isEmpty)
    }
}
