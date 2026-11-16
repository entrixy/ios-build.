import XCTest

final class NavigationUITests: XCTestCase {
    private var activeApp: XCUIApplication?
    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        if (testRun?.failureCount ?? 0) > 0 {
            let frame = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            frame.lifetime = .keepAlways
            add(frame)
            if let app = activeApp { print("NAVIGATION_FAILURE_HIERARCHY\n" + app.debugDescription) }
        }
        activeApp = nil
    }
    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two", route]
        app.launch()
        activeApp = app
        XCTAssertTrue(app.buttons["main-tab-settings"].waitForExistence(timeout: 20))
        return app
    }
    private func assertBottom(_ app: XCUIApplication, _ tabs: [String]) {
        for tab in ["control", "settings", "guests", "journal"] {
            let button = app.buttons["main-tab-" + tab]
            XCTAssertEqual(button.exists, tabs.contains(tab), tab)
            if tabs.contains(tab) {
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    button.exists && button.isHittable
                }, object: button)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, tab)
                XCTAssertGreaterThan(button.frame.minY, app.frame.height * 0.80, tab)
            }
        }
    }
    func testEmptyProfileAndModalCancellation() {
        let app = launch("empty")
        assertBottom(app, ["settings", "journal"])
        app.segmentedControls.buttons["Ключи"].tap()
        app.buttons["Добавить ключ"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["inviteInput"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Отмена"].isHittable)
        app.buttons["Отмена"].tap()
        assertBottom(app, ["settings", "journal"])
        app.buttons["main-tab-journal"].tap()
        XCTAssertTrue(app.staticTexts["Журнал пуст. Здесь будут появляться вызовы."].waitForExistence(timeout: 5))
    }
    func testGuestNestedBackAndRootSwitch() {
        let app = launch("guest-keys")
        assertBottom(app, ["control", "settings", "journal"])
        let key = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "received-key-")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5)); key.tap()
        XCTAssertTrue(app.buttons["Обновить данные"].waitForExistence(timeout: 5))
        assertBottom(app, ["control", "settings", "journal"])
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        XCTAssertTrue(app.buttons["Обновить данные"].waitForExistence(timeout: 5))
        app.buttons["main-tab-journal"].tap()
        app.buttons["main-tab-settings"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Объекты"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Удалить ключ с iPhone"].exists)
    }
    func testOwnerAvailability() {
        let owner = launch("owner-guests")
        XCTAssertTrue(owner.staticTexts["Выданных ключей пока нет"].waitForExistence(timeout: 15))
        assertBottom(owner, ["control", "settings", "guests", "journal"])
        XCTAssertTrue(owner.buttons["Выдать ключ"].exists)
    }
    func testDelegatingGuestAvailabilityAndControlSwitch() {
        let guest = launch("delegating-guests")
        XCTAssertTrue(guest.buttons["Передать полученный доступ"].waitForExistence(timeout: 15))
        assertBottom(guest, ["control", "settings", "guests", "journal"])
        XCTAssertTrue(guest.buttons["Передать полученный доступ"].exists)
        XCTAssertFalse(guest.buttons["Выдать ключ"].exists)
        guest.buttons["main-tab-control"].tap()
        let card = guest.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ворота во двор.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        guest.buttons["main-tab-guests"].tap()
        XCTAssertTrue(guest.buttons["Передать полученный доступ"].waitForExistence(timeout: 15))
    }
}
