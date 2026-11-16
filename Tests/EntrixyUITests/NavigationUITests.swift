import XCTest

final class NavigationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two", route]
        app.launch()
        XCTAssertTrue(app.buttons["main-tab-settings"].waitForExistence(timeout: 20))
        return app
    }
    private func assertBottom(_ app: XCUIApplication, _ tabs: [String]) {
        for tab in ["control", "settings", "guests", "journal"] {
            let button = app.buttons["main-tab-" + tab]
            XCTAssertEqual(button.exists, tabs.contains(tab), tab)
            if tabs.contains(tab) {
                XCTAssertTrue(button.isHittable, tab)
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
    func testOwnerAndDelegatingGuestAvailability() {
        let owner = launch("owner-guests")
        assertBottom(owner, ["control", "settings", "guests", "journal"])
        XCTAssertTrue(owner.buttons["Выдать ключ"].exists)
        owner.terminate()
        let guest = launch("delegating-guests")
        assertBottom(guest, ["control", "settings", "guests", "journal"])
        XCTAssertTrue(guest.buttons["Передать полученный доступ"].exists)
        XCTAssertFalse(guest.buttons["Выдать ключ"].exists)
    }
}
