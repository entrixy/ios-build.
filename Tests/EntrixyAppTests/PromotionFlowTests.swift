import XCTest
import EntrixyCore
@testable import Entrixy

private final class PromotionMemoryStorage: PromotionStorage {
    var state = PromotionState()
    var failing = false
    func load() throws -> PromotionState { if failing { throw URLError(.cannotOpenFile) }; return state }
    func save(_ state:PromotionState) throws { if failing { throw URLError(.cannotWriteToFile) }; self.state = state }
}
private final class PromotionAccessStorage: StateStorage {
    var state = SavedState(identity:Data(repeating:81,count:32),guests:[])
    func load() throws -> SavedState? { state }
    func save(_ state:SavedState) throws { self.state = state }
}
private final class PromotionMockAPI: PromotionTransport {
    var requests: [Data] = []
    var views: [(Int,Int,UUID)] = []
    var record: Promotion?
    var failure = false
    var beforeView: (() -> Void)?
    func fetch(_ body:Data) async throws -> Promotion? {
        requests.append(body); if failure { throw URLError(.notConnectedToInternet) }; return record
    }
    func view(id:Int,count:Int,installID:UUID) async throws {
        beforeView?(); views.append((id,count,installID)); if failure { throw URLError(.notConnectedToInternet) }
    }
}

final class PromotionFlowTests: XCTestCase {
    private func record() throws -> Promotion {
        try Promotion(json:["id":7,"title":"Entrixy","button_text":"Подробнее","button_url":"https://entrixy.com/guide/","display_mode":"until_click"])
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<100 { if predicate() { return }; try? await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertTrue(predicate())
    }
    @MainActor func testUntilClickCommitsBeforeExternalNavigationAndDoesNotTouchAccessIdentity() async throws {
        let access = PromotionAccessStorage(),disk = PromotionMemoryStorage(),api = PromotionMockAPI()
        disk.state.cached = try record(); disk.state.cachedAt = Date(); disk.state.cachedLanguage = ProductText.language
        let app = AppModel(storage:access),before = access.state
        let service = AppPromotions(app:app,storage:disk,api:api); service.activate()
        XCTAssertTrue(api.requests.isEmpty); XCTAssertEqual(service.promotion?.id,7)
        disk.failing = true
        XCTAssertNil(service.clicked(id:7)); XCTAssertEqual(service.promotion?.id,7)
        disk.failing = false
        XCTAssertEqual(service.clicked(id:7)?.absoluteString,"https://entrixy.com/api/go.php?pid=7")
        XCTAssertNil(service.promotion); XCTAssertEqual(disk.state.clicked,[7])
        service.pause()
        let restarted = AppPromotions(app:app,storage:disk,api:api); restarted.activate()
        XCTAssertNil(restarted.promotion); XCTAssertTrue(api.requests.isEmpty)
        XCTAssertEqual(access.state.identity,before.identity); XCTAssertTrue(app.journal.isEmpty)
        restarted.pause()
    }
    @MainActor func testFailedViewRetainsDurableCountsAndCacheWhileDailySuccessWaitsForAcknowledgement() async throws {
        let app = AppModel(storage:PromotionAccessStorage()),disk = PromotionMemoryStorage(),api = PromotionMockAPI()
        disk.state.cached = try record(); disk.state.cachedAt = Date(); disk.state.cachedLanguage = ProductText.language
        api.failure = true
        let service = AppPromotions(app:app,storage:disk,api:api); service.activate()
        api.beforeView = { XCTAssertGreaterThan(disk.state.views["7"] ?? 0,0); XCTAssertNil(disk.state.sentDay) }
        service.viewed(id:7)
        await waitFor { api.views.count == 1 }
        XCTAssertEqual(disk.state.views["7"],1); XCTAssertNil(disk.state.sentDay)
        service.pause(); api.failure = false
        service.activate(); service.viewed(id:7)
        await waitFor { disk.state.sentDay != nil }
        XCTAssertEqual(api.views.last?.1,2); XCTAssertEqual(disk.state.views["7"],0)
        service.viewed(id:7)
        XCTAssertEqual(api.views.count,2); XCTAssertEqual(disk.state.views["7"],1)
        XCTAssertTrue(app.journal.isEmpty); service.pause()
    }
    @MainActor func testUnreadableInstallationStateSendsNothingAndOfflineRefreshKeepsExistingCard() async throws {
        let app = AppModel(storage:PromotionAccessStorage()),disk = PromotionMemoryStorage(),api = PromotionMockAPI()
        let install = disk.state.installID; disk.failing = true
        let service = AppPromotions(app:app,storage:disk,api:api); service.activate()
        XCTAssertTrue(api.requests.isEmpty); XCTAssertNil(service.promotion)
        disk.failing = false; disk.state.cached = try record(); disk.state.cachedAt = Date(timeIntervalSince1970:1)
        disk.state.cachedLanguage = ProductText.language; api.failure = true
        service.activate(); await waitFor { !api.requests.isEmpty }
        XCTAssertEqual(service.promotion?.id,7); XCTAssertEqual(disk.state.installID,install)
        XCTAssertTrue(app.journal.isEmpty); service.pause()
    }
}
