import XCTest

final class NavigationUITests: XCTestCase {
    private var activeApp: XCUIApplication?
    private static var capturedStates = Set<String>()
    private func reviewCapture(_ state: String, settledBy reference: XCUIElement? = nil) {
        guard ProcessInfo.processInfo.environment["ENTRIXY_REVIEW_CAPTURE"] == "1",
              Self.capturedStates.insert(state).inserted else { return }
        // Existence/enabled queries can succeed while a sheet or expanding row
        // is still moving. Keep the original screen capture, after bounded
        // geometric stability; the animated brand itself remains enabled.
        guard let app = activeApp else { XCTFail("Missing app for native checkpoint"); return }
        // Check the foreground app's bounds without asking a detached keyboard
        // Window for a hit point. Explicit control anchors must remain hittable.
        let anchor = reference ?? app
        var previous = CGRect.null
        var unchangedSince = Date()
        let settled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            guard anchor.exists else { unchangedSince = Date(); return false }
            let current = anchor.frame
            guard !current.isEmpty,current.origin.x.isFinite,current.origin.y.isFinite,
                  current.width.isFinite,current.height.isFinite else { unchangedSince = Date(); return false }
            let visible = reference == nil ? app.state == .runningForeground : anchor.isHittable
            guard visible else { unchangedSince = Date(); return false }
            if current != previous { previous = current; unchangedSince = Date(); return false }
            return Date().timeIntervalSince(unchangedSince) >= 0.6
        },object:anchor)
        guard XCTWaiter.wait(for:[settled],timeout:8) == .completed else {
            XCTFail("Native checkpoint did not reach a stable visible layout: " + state); return
        }
        let frame = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        frame.name = "review-" + state; frame.lifetime = .keepAlways; add(frame)
    }
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
    private func nativeSwitch(_ row: XCUIElement) -> XCUIElement {
        let thumb = row.switches.firstMatch
        return thumb.exists ? thumb : row
    }
    private func bringIntoView(_ row: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<22 {
            if row.exists && nativeSwitch(row).isHittable { return }
            let view = list.exists ? list : app
            let down = row.exists && row.frame.maxY < view.frame.minY
            let start = view.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.4 : 0.7))
            let end = view.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.7 : 0.4))
            start.press(forDuration:0.05,thenDragTo:end)
        }
    }
    @discardableResult private func setAutomationRule(_ symbol:String,to enabled:Bool,in app:XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching:.any).matching(identifier:"automation-rule-"+symbol).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10)); bringIntoView(row,in:app)
        let control = nativeSwitch(row), expected = enabled ? "1" : "0"
        if control.value as? String != expected { control.tap() }
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in control.value as? String == expected },object:control)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:5),.completed)
        return control
    }
    private func inspectObjectConditions(_ app:XCUIApplication) {
        setAutomationRule("location",to:true,in:app)
        let route = app.buttons["automation-geo-map"]
        XCTAssertTrue(route.waitForExistence(timeout:10)); bringIntoView(route,in:app)
        reviewCapture("automation-geo",settledBy:route)
        route.tap()
        let mapHost = app.otherElements["automation-route-map"]
        XCTAssertTrue(mapHost.waitForExistence(timeout:15))
        let map = mapHost.maps.firstMatch, draw = app.buttons["route-map-draw"]
        XCTAssertTrue(map.waitForExistence(timeout:15)); XCTAssertTrue(draw.isEnabled); draw.tap()
        XCTAssertFalse(app.buttons["route-map-save"].isEnabled)
        map.coordinate(withNormalizedOffset:CGVector(dx:0.35,dy:0.40)).press(forDuration:0.1,
            thenDragTo:map.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.60)))
        let count = app.staticTexts["route-map-count"]
        let drawn = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in count.label.contains("1") },object:count)
        XCTAssertEqual(XCTWaiter.wait(for:[drawn],timeout:10),.completed)
        XCTAssertTrue(app.buttons["route-map-save"].isEnabled)
        reviewCapture("automation-route-map",settledBy:app.buttons["route-map-save"])
        app.buttons["route-map-save"].tap()
        XCTAssertTrue(route.waitForExistence(timeout:10)); XCTAssertTrue(route.label.contains("1"))
        setAutomationRule("location",to:false,in:app)

        let wifi = setAutomationRule("wifi",to:true,in:app)
        let modes = app.segmentedControls["automation-wifi-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout:10)); bringIntoView(modes,in:app)
        reviewCapture("automation-wifi-connect",settledBy:wifi)
        modes.buttons.element(boundBy:1).tap()
        reviewCapture("automation-wifi-fingerprint",settledBy:modes)
        setAutomationRule("wifi",to:false,in:app)

        setAutomationRule("clock",to:true,in:app)
        let add = app.buttons["automation-time-add"]
        XCTAssertTrue(add.waitForExistence(timeout:10)); bringIntoView(add,in:app); add.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"automation-time-start-0").firstMatch.waitForExistence(timeout:10))
        reviewCapture("automation-time-point",settledBy:add)
        let remove = app.buttons["automation-time-delete-0"]; bringIntoView(remove,in:app); remove.tap()
        let all = app.buttons["automation-combine-all"]; bringIntoView(all,in:app); all.tap()
        bringIntoView(add,in:app); add.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"automation-time-end-0").firstMatch.waitForExistence(timeout:10))
        reviewCapture("automation-time-interval",settledBy:add)
        setAutomationRule("clock",to:false,in:app)
    }
    func testEmptyProfileAndModalCancellation() {
        let app = launch("empty")
        assertBottom(app, ["settings", "journal"])
        reviewCapture("settings-empty")
        app.segmentedControls.buttons["Ключи"].tap()
        app.buttons["Добавить ключ"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["inviteInput"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Отмена"].isHittable)
        reviewCapture("add-key")
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
        reviewCapture("journal")
    }

    func testHomePromotionUsesTheWorkingControlLayoutWithoutOpeningExternalContent() {
        let app = launch("promotion")
        let action = app.buttons["promotion-action"]
        XCTAssertTrue(action.waitForExistence(timeout:10)); XCTAssertTrue(action.isHittable)
        XCTAssertTrue(app.staticTexts["Доступ для ваших гостей"].exists)
        assertBottom(app,["control","settings","guests","journal"])
        reviewCapture("control-promotion",settledBy:action)
        app.buttons["main-tab-settings"].tap()
        XCTAssertTrue(app.buttons["main-tab-control"].isHittable)
    }
    func testIncomingOwnerMessageUsesCompactOverlayUntilCloseAndDoesNotRunAnAction() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two","incoming-message","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch(); activeApp = app
        let title = app.staticTexts["incoming-message-title"]
        XCTAssertTrue(title.waitForExistence(timeout:20))
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"incoming-message-body").firstMatch.exists)
        reviewCapture("message-incoming")
        app.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.15)).tap()
        XCTAssertTrue(title.exists)
        app.buttons["incoming-message-close"].tap()
        XCTAssertTrue(app.buttons["main-tab-control"].waitForExistence(timeout:10))
        XCTAssertFalse(title.exists); assertBottom(app,["control","settings","journal"])
    }
    func testAcceptedKeyShowsOwnerWelcomeUntilOKAndKeepsBottomNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two","key-accepted","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch(); activeApp = app
        let title = app.staticTexts["key-accepted-title"]
        XCTAssertTrue(title.waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts["Владелец пишет:"].exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"key-owner-welcome").firstMatch.exists)
        reviewCapture("key-accepted")
        app.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.15)).tap()
        XCTAssertTrue(title.exists)
        app.buttons["key-accepted-ok"].tap()
        XCTAssertFalse(title.exists); assertBottom(app,["control","settings","journal"])
    }
    func testExistingGuestEditQRMessageAndRemovalUseTheSameIssuedKeyWithoutSending() {
        let app = launch("owner-issued")
        let row = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-card-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10)); XCTAssertTrue(row.label.contains("Анна")); row.tap()
        XCTAssertTrue(app.buttons["Изменить"].isEnabled)
        reviewCapture("guest-issued-actions",settledBy:app.buttons["issue-guest"])
        app.buttons["Изменить"].tap()
        XCTAssertTrue(app.textFields.matching(NSPredicate(format:"value == %@","Анна")).firstMatch.waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["Сохранить"].exists)
        reviewCapture("guest-issued-edit")
        app.buttons["Отмена"].tap(); XCTAssertTrue(row.waitForExistence(timeout:10))
        app.buttons["QR"].tap()
        XCTAssertTrue(app.navigationBars["QR"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["Копировать"].exists); reviewCapture("guest-issued-qr",settledBy:app.buttons["Закрыть"])
        app.buttons["Закрыть"].tap()
        app.buttons["Отправить сообщение"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"message-text").firstMatch.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["message-send"].isEnabled); reviewCapture("message-compose")
        app.buttons["Отмена"].tap()
        app.buttons["Удалить"].tap()
        XCTAssertTrue(app.staticTexts["Удалить ключ?"].waitForExistence(timeout:10)); reviewCapture("guest-revoke-confirmation")
        app.buttons["Отмена"].tap(); XCTAssertTrue(row.exists)
        assertBottom(app,["control","settings","guests","journal"])
    }
    func testGuestPresetsAndCompaniesKeepRootNavigationAndShowActualAccessControls() {
        let app = launch("owner-guests")
        app.segmentedControls.buttons["Пресеты"].tap()
        XCTAssertTrue(app.staticTexts["Доступ для новых ключей"].waitForExistence(timeout:10))
        XCTAssertTrue(app.switches.matching(NSPredicate(format:"label CONTAINS %@","Разрешить передавать дальше")).firstMatch.exists)
        reviewCapture("guest-presets")
        app.segmentedControls.buttons["Компании"].tap()
        XCTAssertTrue(app.buttons["company-scan"].waitForExistence(timeout:10))
        reviewCapture("guest-companies")
        assertBottom(app,["control","settings","guests","journal"])
    }
    func testSoundSettingsAndBackupPasswordFormUseRealControlsWithoutExporting() {
        let app = launch("empty")
        app.segmentedControls.buttons["Звуки"].tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout:10))
        XCTAssertGreaterThan(app.switches.count,0); reviewCapture("sounds")
        app.segmentedControls.buttons["Система"].tap()
        let create = app.buttons["Создать копию"]
        bringIntoView(create,in:app); XCTAssertTrue(create.isHittable); create.tap()
        XCTAssertTrue(app.secureTextFields["Пароль копии"].waitForExistence(timeout:10))
        XCTAssertTrue(app.secureTextFields["Повторите пароль"].exists)
        XCTAssertFalse(app.buttons["Сохранить"].isEnabled)
        let save = app.buttons["Сохранить"], send = app.buttons["Отправить"], cancel = app.buttons["Отмена"]
        XCTAssertEqual(save.frame.height,send.frame.height,accuracy:1)
        XCTAssertEqual(save.frame.minY,send.frame.minY,accuracy:1)
        XCTAssertGreaterThanOrEqual(cancel.frame.minY,save.frame.maxY)
        reviewCapture("backup-password",settledBy:cancel)
        app.buttons["Отмена"].tap()
        assertBottom(app,["settings","journal"])
    }
    func testHomeNetworkConsentAndRemovalUseSystemSectionAndPreserveReceivedKeys() {
        let app = launch("network-privacy")
        let row = app.descendants(matching:.any).matching(identifier:"privacy-cellular-consent").firstMatch
        for _ in 0..<12 {
            if row.exists {
                let control = nativeSwitch(row)
                if control.exists && control.isHittable { break }
            }
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout:5))
        let toggle = nativeSwitch(row)
        XCTAssertTrue(toggle.exists); XCTAssertTrue(toggle.isHittable); XCTAssertEqual(toggle.value as? String,"0")
        reviewCapture("home-network")
        toggle.tap()
        let enabled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in toggle.value as? String == "1" },object:toggle)
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:5),.completed)
        let remove = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","privacy-remove-")).firstMatch
        for _ in 0..<8 { if remove.exists && remove.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(remove.exists); XCTAssertTrue(remove.isHittable); remove.tap()
        let gone = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !remove.exists },object:remove)
        XCTAssertEqual(XCTWaiter.wait(for:[gone],timeout:5),.completed)
        assertBottom(app,["control","settings","journal"])
        app.segmentedControls.buttons["Ключи"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","received-key-")).firstMatch.waitForExistence(timeout:5))
    }
    func testOrdinaryEmptyStartupAndThemeChangeKeepTheLiveRootInteractive() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-offline-promotions","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch(); activeApp = app
        let later = app.buttons["diagnostic-consent-later"]
        if later.waitForExistence(timeout:5) { later.tap() }
        XCTAssertTrue(app.buttons["main-tab-settings"].waitForExistence(timeout:20))
        assertBottom(app,["settings","journal"])
        app.segmentedControls.buttons["Система"].tap()
        XCTAssertTrue(app.buttons["theme-light"].waitForExistence(timeout:10)); app.buttons["theme-light"].tap()
        reviewCapture("system")
        assertBottom(app,["settings","journal"])
        app.buttons["main-tab-journal"].tap()
        XCTAssertTrue(app.staticTexts["Журнал пуст. Здесь будут появляться вызовы."].waitForExistence(timeout:5))
    }
    func testCrashConsentAndSevenTapDeveloperLogUseNativeSettingsAndPreserveNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two","diagnostics","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch(); activeApp = app
        let later = app.buttons["diagnostic-consent-later"], allow = app.buttons["diagnostic-consent-allow"]
        XCTAssertTrue(later.waitForExistence(timeout:15)); XCTAssertTrue(allow.isHittable)
        reviewCapture("crash-consent")
        XCTAssertEqual(later.frame.height,allow.frame.height,accuracy:1); later.tap()
        XCTAssertTrue(app.buttons["main-tab-settings"].waitForExistence(timeout:10))
        let row = app.descendants(matching:.any).matching(identifier:"diagnostics-consent-switch").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10))
        let control = nativeSwitch(row)
        XCTAssertEqual(control.value as? String,"0"); control.tap()
        let enabled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in control.value as? String == "1" },object:control)
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:5),.completed)
        XCTAssertFalse(app.buttons["diagnostics-send"].exists)
        reviewCapture("diagnostic-settings")
        app.buttons["header-help"].tap()
        reviewCapture("help")
        let version = app.descendants(matching:.any).matching(identifier:"help-version").firstMatch
        for _ in 0..<14 { if version.exists && version.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(version.isHittable)
        for _ in 0..<7 { version.tap() }
        XCTAssertTrue(app.staticTexts["Режим разработчика включён"].waitForExistence(timeout:5))
        app.navigationBars.buttons.element(boundBy:0).tap()
        let send = app.buttons["diagnostics-send"]
        for _ in 0..<14 { if send.exists && send.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(send.isHittable); send.tap()
        XCTAssertTrue(app.staticTexts["Технический журнал отправлен."].waitForExistence(timeout:10))
        reviewCapture("developer-report")
        let off = app.buttons["developer-disable"]
        for _ in 0..<4 { if off.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(off.isHittable); off.tap()
        let hidden = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !send.exists },object:send)
        XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:5),.completed)
        assertBottom(app,["control","settings","journal"])
    }
    func testCardConfirmationAndCodeSetupUseCompactDialogAndCancelWithoutLeavingControl() {
        for route in ["owner-confirmation","owner-code-confirmation"] {
            let app = launch(route)
            let card = app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Ворота во двор.")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout:10)); card.tap()
            let dialog = app.staticTexts["action-confirmation-title"]
            XCTAssertTrue(dialog.waitForExistence(timeout:10))
            XCTAssertFalse(app.navigationBars["Подтвердить действие"].exists)
            XCTAssertTrue(app.buttons["Отмена"].isHittable)
            if route == "owner-code-confirmation" {
                XCTAssertTrue(app.secureTextFields["Код Entrixy"].exists)
                XCTAssertTrue(app.secureTextFields["Повторите код"].exists)
                XCTAssertFalse(app.buttons["action-confirmation-submit"].isEnabled)
                reviewCapture("action-code-setup")
            } else {
                XCTAssertTrue(app.buttons["action-confirmation-submit"].isEnabled)
                XCTAssertLessThan(app.buttons["Отмена"].frame.maxY-dialog.frame.minY,app.frame.height * 0.6)
                reviewCapture("action-confirmation")
            }
            app.buttons["Отмена"].tap()
            XCTAssertFalse(dialog.exists)
            assertBottom(app,["control","settings","guests","journal"])
            XCTAssertTrue(card.exists)
            app.terminate()
        }
    }
    func testFactoryClaimLinkPreparesDeviceFormWithOriginalServerAndCancelDoesNotRegister() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two","device-claim","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch(); activeApp = app
        let code = app.textFields["device-claim-code"]
        XCTAssertTrue(code.waitForExistence(timeout:20)); XCTAssertEqual(code.value as? String,"A1B2C3D4")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","factory.invalid:8443")).firstMatch.exists)
        XCTAssertTrue(app.textFields["Название"].exists)
        reviewCapture("device-claim")
        app.buttons["Отмена"].tap()
        assertBottom(app,["settings","journal"])
        XCTAssertTrue(app.staticTexts["Пока нет объектов"].exists)
        XCTAssertFalse(app.buttons["main-tab-guests"].exists)
    }
    func testOwnedBLEInformationUsesSeparateActionAndDoesNotInventUnobservedReadings() {
        let app = launch("owner-ble-objects")
        let info = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","object-info-owner:")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout:10)); info.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Данных пока нет")).firstMatch.waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["Заряд батареи"].exists)
        XCTAssertFalse(app.staticTexts["0%"].exists)
        reviewCapture("ble-information")
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(info.waitForExistence(timeout:10))
        assertBottom(app,["control","settings","guests","journal"])
        app.buttons["main-tab-guests"].tap(); app.buttons["issue-guest"].tap()
        let object = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-object-owner:")).firstMatch
        XCTAssertTrue(object.waitForExistence(timeout:10)); object.tap()
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-object-invocation-")).firstMatch.tap()
        let lifetime = app.sliders["guest-ble-lifetime"], value = app.staticTexts["guest-ble-lifetime-value"]
        XCTAssertTrue(lifetime.waitForExistence(timeout:10)); let previous = value.label
        lifetime.adjust(toNormalizedSliderPosition:0)
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in value.label != previous },object:value)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:5),.completed)
        reviewCapture("guest-ble-lifetime",settledBy:lifetime)
        app.buttons["Закрыть"].tap(); app.buttons["Отмена"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-card-")).firstMatch.exists)
    }
    func testGuestNestedBackAndRootSwitch() {
        let app = launch("guest-keys")
        assertBottom(app, ["control", "settings", "journal"])
        let key = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "received-key-")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5)); key.tap()
        XCTAssertTrue(app.buttons["Обновить данные"].waitForExistence(timeout: 5))
        reviewCapture("received-key-detail")
        app.buttons["Удалить ключ с iPhone"].tap()
        XCTAssertTrue(app.staticTexts["Удалить ключ?"].waitForExistence(timeout:5))
        let cancel = app.buttons["Отмена"], remove = app.buttons["Удалить ключ"]
        XCTAssertTrue(cancel.isHittable); XCTAssertTrue(remove.isHittable)
        XCTAssertEqual(cancel.frame.height,remove.frame.height,accuracy:1)
        reviewCapture("received-key-delete-confirmation")
        cancel.tap()
        XCTAssertTrue(app.buttons["Обновить данные"].waitForExistence(timeout:5))
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
        reviewCapture("guests-owner")
    }
    func testDelegatingGuestAvailabilityAndControlSwitch() {
        let guest = launch("delegating-guests")
        XCTAssertTrue(guest.buttons["pass-received-access"].waitForExistence(timeout: 15))
        assertBottom(guest, ["control", "settings", "guests", "journal"])
        XCTAssertTrue(guest.buttons["pass-received-access"].exists)
        XCTAssertFalse(guest.buttons["issue-guest"].exists)
        reviewCapture("guests-delegating")
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
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Yard\n")
        XCTAssertEqual(field.value as? String,"Yard")
        reviewCapture("object-rename")
        app.buttons["Сохранить"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "object-settings-guest:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let renamed = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in row.exists && row.label.contains("Yard") },object:row)
        XCTAssertEqual(XCTWaiter.wait(for:[renamed],timeout:10),.completed)
        assertBottom(app,["control","settings","journal"])
        app.buttons["main-tab-control"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Yard.")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["main-tab-settings"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if !app.buttons["Скрыть"].exists { row.tap() }
        app.buttons["Скрыть"].tap()
        XCTAssertTrue(app.buttons["Скрыть объект"].waitForExistence(timeout:5))
        reviewCapture("object-hide")
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
        reviewCapture("ble-pairing")
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
        reviewCapture("settings-objects")
        app.buttons["main-tab-control"].tap()
        func card(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ".")).firstMatch }
        let bleCard = card("Дверь Bluetooth"), ownCard = card("Ворота во двор"), guestCard = card("Гостевой въезд")
        XCTAssertTrue(bleCard.waitForExistence(timeout: 10)); XCTAssertTrue(ownCard.exists); XCTAssertTrue(guestCard.exists)
        XCTAssertLessThan(bleCard.frame.minY, ownCard.frame.minY); XCTAssertLessThan(ownCard.frame.minY, guestCard.frame.minY)
        assertBottom(app, ["control", "settings", "guests", "journal"])
        reviewCapture("control")
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
        reviewCapture("add-object-call")
    }
    func testActualWebhookEditorContainsAndroidFieldsAndAutomationRoute() {
        let app = launch("owner-expanded")
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","object-edit-owner:")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Редактировать объект"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Название"].value as? String, "Ворота во двор")
        XCTAssertFalse(app.staticTexts["Значок объекта"].exists)
        XCTAssertFalse(app.buttons["Сохранить защиту"].exists)
        XCTAssertTrue(app.buttons["owner-object-automation"].isHittable)
        reviewCapture("object-webhook-edit")
        app.buttons["owner-object-automation"].tap()
        XCTAssertTrue(app.staticTexts["Условия"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Wi-Fi"].exists)
        XCTAssertTrue(app.buttons["Закрыть"].exists)
        reviewCapture("automation-owner")
        inspectObjectConditions(app)
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["owner-object-automation"].waitForExistence(timeout: 10))
        let camera = app.descendants(matching:.any).matching(identifier:"object-camera-enabled").firstMatch
        bringIntoView(camera,in:app); nativeSwitch(camera).tap()
        let address = app.textFields["object-camera-url"]
        XCTAssertTrue(address.waitForExistence(timeout:10)); bringIntoView(address,in:app)
        for _ in 0..<5 {
            if address.frame.minY <= app.frame.height*0.30 { break }
            app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.72)).press(forDuration:0.05,
                thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.48)))
        }
        reviewCapture("object-camera-settings",settledBy:address)
    }

    func testCallGuestPreferencesAndDeviceAccessUseActualEditorsWithoutIssuingOrConnecting() {
        let app = launch("owner-call-guests")
        app.buttons["issue-guest"].tap()
        let object = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-object-owner:")).firstMatch
        XCTAssertTrue(object.waitForExistence(timeout:10)); object.tap()
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-object-invocation-")).firstMatch.tap()
        let reaction = app.descendants(matching:.any).matching(identifier:"guest-call-enabled").firstMatch
        XCTAssertTrue(reaction.waitForExistence(timeout:10))
        if nativeSwitch(reaction).value as? String != "1" { nativeSwitch(reaction).tap() }
        XCTAssertTrue(app.buttons["guest-call-reaction-confirm"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["guest-call-reaction-auto"].exists)
        reviewCapture("guest-call-preferences",settledBy:app.buttons["guest-call-reaction-confirm"])
        app.buttons["Закрыть"].tap(); app.buttons["Отмена"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-card-")).firstMatch.exists)

        let device = launch("owner-device-objects")
        device.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","object-settings-owner:")).firstMatch.tap()
        device.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","object-edit-owner:")).firstMatch.tap()
        let share = device.buttons["device-share-credentials"]
        XCTAssertTrue(share.waitForExistence(timeout:10)); bringIntoView(share,in:device)
        reviewCapture("object-device-settings",settledBy:share); share.tap()
        XCTAssertTrue(device.staticTexts["Код устройства"].waitForExistence(timeout:10))
        XCTAssertTrue(device.buttons["Копировать"].exists)
        reviewCapture("device-access-parameters",settledBy:device.buttons["Готово"])
        device.buttons["Готово"].tap()
        XCTAssertTrue(share.waitForExistence(timeout:10))
    }
    func testAvatarPickerOpensFromAvatarAndKeepsObjectRow() {
        let app = launch("owner-objects")
        let avatar = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","object-avatar-owner:")).firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout:10)); XCTAssertGreaterThanOrEqual(avatar.frame.width,44); XCTAssertGreaterThanOrEqual(avatar.frame.height,44)
        avatar.tap()
        for index in 1...8 { XCTAssertTrue(app.buttons["Иконка \(index)"].waitForExistence(timeout: 10)) }
        XCTAssertTrue(app.buttons["Загрузить иконку"].exists)
        let avatarCancel = app.buttons["avatar-cancel"], avatarUpload = app.buttons["avatar-upload"]
        XCTAssertTrue(avatarCancel.isHittable); XCTAssertTrue(avatarUpload.isHittable)
        XCTAssertEqual(avatarCancel.frame.height,avatarUpload.frame.height,accuracy:1)
        XCTAssertEqual(avatarCancel.frame.width,avatarUpload.frame.width,accuracy:1)
        XCTAssertGreaterThanOrEqual(avatarUpload.frame.height,48)
        reviewCapture("object-avatar",settledBy:avatarUpload)
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
        reviewCapture("guest-issue-object")
        app.buttons["Автоматизация для гостя"].tap()
        XCTAssertTrue(app.staticTexts["Условия"].waitForExistence(timeout: 10))
        reviewCapture("automation-guest")
        app.buttons["Закрыть"].tap()
        app.buttons["Доступ к объекту"].tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Только для приложения")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Разрешить передавать дальше")).firstMatch.exists)
        reviewCapture("guest-access-limits")
        app.buttons["ОК"].firstMatch.tap()
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.buttons["issue-guest"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-card-")).firstMatch.exists)
        // Form inspection never saves a key, sends a command or opens a camera.
    }

    func testPassedAccessUsesObjectCheckboxAndBoundedAccessEditorWithoutServerPicker() {
        let app = launch("delegating-guests")
        let pass = app.buttons["pass-received-access"]
        XCTAssertTrue(pass.waitForExistence(timeout:15)); pass.tap()
        let object = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","pass-object-")).firstMatch
        XCTAssertTrue(object.waitForExistence(timeout:10)); XCTAssertFalse(app.pickers["Сервер"].exists)
        reviewCapture("access-pass")
        object.tap(); app.buttons["Настройки доступа"].tap()
        XCTAssertTrue(app.staticTexts["Получатель передать доступ дальше не сможет"].waitForExistence(timeout:10))
        XCTAssertFalse(app.switches.matching(NSPredicate(format:"label CONTAINS %@","Только для приложения")).firstMatch.exists)
        reviewCapture("passed-access-limits")
        app.buttons["ОК"].tap(); app.buttons["Отмена"].tap()
        assertBottom(app,["control","settings","guests","journal"])
    }

    func testServerRowsAndCompactAccountDialogStayInSystemAndCancelWithoutRegistration() {
        let app = launch("empty")
        app.segmentedControls.buttons["Система"].tap()
        let add = app.buttons["server-add"]
        for _ in 0..<6 { if add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable); XCTAssertTrue(app.buttons["server-select-entrixy.com"].exists)
        add.tap()
        let host = app.textFields["server-host"]
        XCTAssertTrue(host.waitForExistence(timeout:10)); XCTAssertTrue(host.isEnabled)
        XCTAssertTrue(app.textFields["Почта"].exists); XCTAssertTrue(app.secureTextFields["Пароль"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Отмена"].exists)
        let cancel = app.buttons["Отмена"]
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(app.frame.insetBy(dx:0,dy:1).contains(cancel.frame))
        reviewCapture("server-account",settledBy:cancel)
        cancel.tap()
        XCTAssertTrue(add.waitForExistence(timeout:10)); assertBottom(app,["settings","journal"])
    }

    func testEntryLockSettingsUseCompactCodeDialogsAndWrongCodeCannotDisableLock() {
        let app = launch("empty")
        app.segmentedControls.buttons["Система"].tap()
        let lock = app.descendants(matching:.any).matching(identifier:"entry-lock-toggle").firstMatch
        // iOS exposes the whole labelled row and its actual UISwitch as nested
        // Switch elements. Activate the real control, rather than the row's
        // geometric centre (which is the label, outside the switch hit region).
        func tapLock() {
            bringIntoView(lock,in:app)
            let thumb = nativeSwitch(lock)
            XCTAssertTrue(thumb.isHittable); thumb.tap()
        }
        tapLock()
        let code = app.secureTextFields["Код Entrixy"], repeated = app.secureTextFields["Повторите код"]
        XCTAssertTrue(code.waitForExistence(timeout:10)); XCTAssertTrue(repeated.exists)
        code.tap(); code.typeText("1234"); repeated.tap(); repeated.typeText("1234")
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.buttons["Сменить код"].waitForExistence(timeout:15))
        XCTAssertEqual(lock.value as? String,"1")
        tapLock()
        let current = app.secureTextFields["Текущий код"]
        XCTAssertTrue(current.waitForExistence(timeout:10)); current.tap(); current.typeText("0000")
        app.buttons["ОК"].tap()
        XCTAssertTrue(app.staticTexts["Неверный код"].waitForExistence(timeout:10))
        reviewCapture("entry-code-rejected")
        app.buttons["Отмена"].tap()
        XCTAssertEqual(lock.value as? String,"1")
        tapLock(); XCTAssertTrue(current.waitForExistence(timeout:10))
        current.tap(); current.typeText("1234"); app.buttons["ОК"].tap()
        let disabled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in lock.exists && lock.value as? String == "0" },object:lock)
        XCTAssertEqual(XCTWaiter.wait(for:[disabled],timeout:15),.completed)
        assertBottom(app,["settings","journal"])
    }

}
