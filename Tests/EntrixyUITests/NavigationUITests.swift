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
        app.launchArguments = ["--stage-two", route, "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
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
        app.segmentedControls.buttons["Объекты"].tap()
        app.buttons["Добавить объект"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["owner-object-kind"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Название"].exists)
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
        XCTAssertTrue(owner.segmentedControls.buttons["Пресеты"].waitForExistence(timeout: 15))
        assertBottom(owner, ["control", "settings", "guests", "journal"])
        XCTAssertTrue(owner.buttons["issue-guest"].exists)
    }
    func testDelegatingGuestAvailabilityAndControlSwitch() {
        let guest = launch("delegating-guests")
        XCTAssertTrue(guest.buttons["pass-received-access"].waitForExistence(timeout: 15))
        assertBottom(guest, ["control", "settings", "guests", "journal"])
        XCTAssertTrue(guest.buttons["pass-received-access"].exists)
        XCTAssertFalse(guest.buttons["issue-guest"].exists)
        guest.buttons["main-tab-control"].tap()
        let card = guest.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ворота во двор.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        guest.buttons["main-tab-guests"].tap()
        XCTAssertTrue(guest.buttons["pass-received-access"].waitForExistence(timeout: 15))
    }
    func testReceivedObjectRenameAndHideKeepTheKey() {
        let app = launch("guest-expanded")
        XCTAssertTrue(app.buttons["Название"].waitForExistence(timeout: 10))
        app.buttons["Название"].tap()
        let field = app.textFields["Название"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Yard")
        app.buttons["Сохранить"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "object-settings-guest:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.buttons["main-tab-control"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Yard.")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["main-tab-settings"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if !app.buttons["Скрыть"].exists { row.tap() }
        app.buttons["Скрыть"].tap()
        app.buttons["Скрыть объект"].tap()
        XCTAssertTrue(app.staticTexts["Пока нет объектов"].waitForExistence(timeout: 10))
        assertBottom(app, ["settings", "journal"])
        app.segmentedControls.buttons["Ключи"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "received-key-")).firstMatch.waitForExistence(timeout: 10))
    }
    func testBLECreationStartsFromAddObjectAndKeepsItsName() {
        let app = launch("owner-objects")
        XCTAssertFalse(app.buttons["Привязать Bluetooth-контроллер"].exists)
        app.buttons["Добавить объект"].tap()
        app.buttons["owner-object-type-ble"].tap()
        let field = app.textFields["Название"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("BLE Yard\n")
        let save = app.buttons["Сохранить"]
        if !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.buttons["Найти контроллеры"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Название объекта"].value as? String, "BLE Yard")
        XCTAssertTrue(app.buttons["Отмена"].exists)
        // No scan, pairing or physical command is issued by this test.
    }
    func testMixedObjectsUseTheSameInterleavedOrderInBothRoots() {
        let app = launch("mixed-objects")
        func row(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "object-settings-", name)).firstMatch
        }
        let ble = row("Дверь Bluetooth"), own = row("Ворота во двор"), guest = row("Гостевой въезд")
        XCTAssertTrue(ble.waitForExistence(timeout: 10)); XCTAssertTrue(own.exists); XCTAssertTrue(guest.exists)
        XCTAssertLessThan(ble.frame.minY, own.frame.minY); XCTAssertLessThan(own.frame.minY, guest.frame.minY)
        app.buttons["main-tab-control"].tap()
        func card(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ".")).firstMatch }
        let bleCard = card("Дверь Bluetooth"), ownCard = card("Ворота во двор"), guestCard = card("Гостевой въезд")
        XCTAssertTrue(bleCard.waitForExistence(timeout: 10)); XCTAssertTrue(ownCard.exists); XCTAssertTrue(guestCard.exists)
        XCTAssertLessThan(bleCard.frame.minY, ownCard.frame.minY); XCTAssertLessThan(ownCard.frame.minY, guestCard.frame.minY)
        assertBottom(app, ["control", "settings", "guests", "journal"])
    }
    func testObjectCreationUsesAndroidTypeOrderAndDefaultCall() {
        let app = launch("empty")
        app.buttons["Добавить объект"].tap()
        let types = ["call", "webhook", "device", "ble"].map { app.buttons["owner-object-type-" + $0] }
        for button in types { XCTAssertTrue(button.waitForExistence(timeout: 10)) }
        for index in 1..<types.count { XCTAssertLessThan(types[index-1].frame.minY, types[index].frame.minY) }
        XCTAssertTrue(types[0].isSelected)
        XCTAssertTrue(app.textFields["Номер для звонка"].exists)
        XCTAssertTrue(app.buttons["Добавить из контактов"].exists)
        XCTAssertGreaterThan(app.textFields["Название"].frame.minY, types.last!.frame.minY)
    }
    func testActualWebhookEditorContainsAndroidFieldsAndAutomationRoute() {
        let app = launch("owner-expanded")
        app.buttons["Настройки"].tap()
        XCTAssertTrue(app.navigationBars["Редактировать объект"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Название"].value as? String, "Ворота во двор")
        XCTAssertFalse(app.staticTexts["Значок объекта"].exists)
        XCTAssertFalse(app.buttons["Сохранить защиту"].exists)
        XCTAssertTrue(app.buttons["owner-object-automation"].isHittable)
        app.buttons["owner-object-automation"].tap()
        XCTAssertTrue(app.staticTexts["Условия"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Wi-Fi"].exists)
        XCTAssertTrue(app.buttons["Закрыть"].exists)
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["owner-object-automation"].waitForExistence(timeout: 10))
    }
    func testAvatarPickerOpensFromAvatarAndKeepsObjectRow() {
        let app = launch("owner-objects")
        app.buttons["Иконка объекта"].tap()
        for index in 1...8 { XCTAssertTrue(app.buttons["Иконка \(index)"].waitForExistence(timeout: 10)) }
        XCTAssertTrue(app.buttons["Загрузить иконку"].exists)
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "object-settings-owner:")).firstMatch.waitForExistence(timeout: 10))
    }

    func testGuestSettingsStayOnTheSelectedObjectRowWithoutIssuingAKey() {
        let app = launch("owner-guests")
        app.buttons["issue-guest"].tap()
        let object = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guest-object-owner:")).firstMatch
        XCTAssertTrue(object.waitForExistence(timeout: 10)); object.tap()
        XCTAssertTrue(app.buttons["Настройки реакции на звонок"].exists)
        XCTAssertTrue(app.buttons["Автоматизация для гостя"].exists)
        XCTAssertTrue(app.buttons["Доступ к объекту"].exists)
        XCTAssertFalse(app.switches["Подтверждать нажатие перед открытием"].exists)
        app.buttons["Автоматизация для гостя"].tap()
        XCTAssertTrue(app.staticTexts["Условия"].waitForExistence(timeout: 10))
        app.buttons["Закрыть"].tap()
        app.buttons["Доступ к объекту"].tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Только для приложения")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Разрешить передавать дальше")).firstMatch.exists)
        app.buttons["ОК"].firstMatch.tap()
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.buttons["issue-guest"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-card-")).firstMatch.exists)
        // Form inspection never saves a key, sends a command or opens a camera.
    }

    func testEntryLockSettingsUseCompactCodeDialogsAndWrongCodeCannotDisableLock() {
        let app = launch("empty")
        app.segmentedControls.buttons["Система"].tap()
        let lock = app.switches.matching(NSPredicate(format:"label CONTAINS %@","Спрашивать код при входе")).firstMatch
        for _ in 0..<4 { if lock.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(lock.isHittable); lock.tap()
        let code = app.secureTextFields["Код Entrixy"], repeated = app.secureTextFields["Повторите код"]
        XCTAssertTrue(code.waitForExistence(timeout:10)); XCTAssertTrue(repeated.exists)
        code.tap(); code.typeText("1234"); repeated.tap(); repeated.typeText("1234")
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.buttons["Сменить код"].waitForExistence(timeout:15))
        XCTAssertEqual(lock.value as? String,"1")
        lock.tap()
        let current = app.secureTextFields["Текущий код"]
        XCTAssertTrue(current.waitForExistence(timeout:10)); current.tap(); current.typeText("0000")
        app.buttons["ОК"].tap()
        XCTAssertTrue(app.staticTexts["Неверный код"].waitForExistence(timeout:10))
        app.buttons["Отмена"].tap()
        XCTAssertEqual(lock.value as? String,"1")
        lock.tap(); XCTAssertTrue(current.waitForExistence(timeout:10))
        current.tap(); current.typeText("1234"); app.buttons["ОК"].tap()
        let disabled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in lock.exists && lock.value as? String == "0" },object:lock)
        XCTAssertEqual(XCTWaiter.wait(for:[disabled],timeout:15),.completed)
        assertBottom(app,["settings","journal"])
    }

}
