import XCTest
@testable import EntrixyCore

final class WidgetTapTests: XCTestCase {
    func testIdentifiersKeepServerAndGuestScopesSeparateWithoutExposingThem() {
        let uuid = UUID(), first = ObjectReference.owned(server:"first.invalid",objectID:uuid)
        let second = ObjectReference.owned(server:"second.invalid",objectID:uuid)
        let guest = ObjectReference.received(guestID:"private invitation",objectID:uuid.uuidString)
        let ids = [first,second,guest].map(WidgetObjectID.forTarget)
        XCTAssertEqual(Set(ids).count,3); XCTAssertTrue(ids.allSatisfy(WidgetObjectID.valid))
        XCTAssertFalse(ids.joined().contains("invalid")); XCTAssertFalse(ids.joined().contains("invitation"))
    }
    func testOneInvocationIsConsumedBeforeActionAndCannotReturnAfterFailureOrResume() {
        var queue = WidgetTapQueue(); let id = UUID(), date = Date()
        let target = String(repeating:"a",count:64)
        XCTAssertTrue(queue.enqueue(objectID:target,id:id,at:date))
        XCTAssertNotNil(queue.consume(id,at:date)); XCTAssertNil(queue.consume(id,at:date))
        XCTAssertFalse(queue.enqueue(objectID:target,id:id,at:date.addingTimeInterval(1)))
        XCTAssertNil(queue.current(at:date.addingTimeInterval(2)))
        XCTAssertNil(WidgetTapQueue().pending)
    }
    func testExpiredAndFutureTapsAreDiscardedInsteadOfFiringAfterUnlock() {
        let date = Date(), target = String(repeating:"b",count:64)
        var queue = WidgetTapQueue()
        XCTAssertTrue(queue.enqueue(objectID:target,at:date)); XCTAssertNil(queue.current(at:date.addingTimeInterval(61)))
        XCTAssertNil(queue.current(at:date))
        XCTAssertTrue(queue.enqueue(objectID:target,at:date)); XCTAssertNil(queue.current(at:date.addingTimeInterval(-1)))
    }
    func testNewTapReplacesOldTargetAndInvalidInputCannotDisplaceIt() {
        let date = Date(), first = UUID(), second = UUID()
        var queue = WidgetTapQueue()
        XCTAssertTrue(queue.enqueue(objectID:String(repeating:"a",count:64),id:first,at:date))
        XCTAssertTrue(queue.enqueue(objectID:String(repeating:"b",count:64),id:second,at:date))
        XCTAssertFalse(queue.enqueue(objectID:"entrixy://widget?fire=1",at:date))
        XCTAssertNil(queue.consume(first,at:date)); XCTAssertEqual(queue.consume(second,at:date)?.objectID,String(repeating:"b",count:64))
        XCTAssertTrue(queue.enqueue(objectID:String(repeating:"c",count:64),at:date))
        queue.cancel(); XCTAssertNil(queue.current(at:date))
    }
}
