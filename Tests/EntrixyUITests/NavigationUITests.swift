import XCTest

final class NavigationUITests: XCTestCase {
    private var activeApp: XCUIApplication?
    private static var capturedStates = Set<String>()
    private func reviewCapture(_ state: String, settledBy reference: XCUIElement? = nil) {
        let capture = ProcessInfo.processInfo.environment["ENTRIXY_REVIEW_CAPTURE"] == "1"
        guard capture || ProcessInfo.processInfo.environment["ENTRIXY_CHECKPOINT_ASSERTIONS"] == "1" else { return }
        guard
              Self.capturedStates.insert(state).inserted else { return }
        // Existence/enabled queries can succeed while a sheet or expanding row
        // is still moving. Keep the original screen capture, after bounded
        // geometric stability; the animated brand itself remains enabled.
        guard let app = activeApp else { XCTFail("Missing app for native checkpoint"); return }
        // Check the foreground app's bounds without asking a detached keyboard
        // Window for a hit point. Buttons retain their hittability check;
        // SwiftUI switches are exercised at their actual rendered thumb bounds.
        let requireHit = reference.map { $0.elementType != .switch } ?? false
        guard waitForStable(reference ?? app,in:app,requireHit:requireHit) else {
            XCTFail("Native checkpoint did not reach a stable visible layout: " + state); return
        }
        guard capture else { return }
        let frame = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        frame.name = "review-" + state; frame.lifetime = .keepAlways; add(frame)
    }
    private func waitForStable(_ anchor:XCUIElement,in app:XCUIApplication,requireHit:Bool = true) -> Bool {
        var previous = CGRect.null
        var unchangedSince = Date()
        let deadline = Date().addingTimeInterval(20)
        var samples: [String] = []
        // XCTest's expectation-object descriptions can consume the entire
        // deadline collecting a hierarchy before the second observation.
        while Date() < deadline {
            if anchor.exists {
                let current = anchor.frame
                let valid = !current.isEmpty && current.origin.x.isFinite && current.origin.y.isFinite && current.width.isFinite && current.height.isFinite
                let visible = requireHit ? anchor.isHittable : app.state == .runningForeground
                samples.append("rect=\(current), valid=\(valid), visible=\(visible)")
                if valid && visible {
                    let same = !previous.isNull && abs(current.minX-previous.minX) <= 0.5 && abs(current.minY-previous.minY) <= 0.5 && abs(current.width-previous.width) <= 0.5 && abs(current.height-previous.height) <= 0.5
                    if same && Date().timeIntervalSince(unchangedSince) >= 0.6 { return true }
                    if !same { previous = current; unchangedSince = Date() }
                } else { unchangedSince = Date() }
            } else { samples.append("missing"); unchangedSince = Date() }
            RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        }
        print("STABILITY_FAILURE requireHit=\(requireHit): " + samples.joined(separator:"; "))
        return false
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
        // SwiftUI exposes the labelled Toggle as the actionable switch. Its
        // UIKit implementation child can exist while being non-hittable.
        if row.elementType == .switch { return row }
        let thumb = row.switches.firstMatch
        return thumb.exists ? thumb : row
    }
    private func bringIntoView(_ row: XCUIElement, in app: XCUIApplication) {
        bringFullyIntoView(row,in:app)
        let control = nativeSwitch(row)
        XCTAssertTrue(waitForStable(control,in:app,requireHit:control.elementType != .switch),"Control did not settle before interaction")
        XCTAssertTrue(control.isEnabled)
    }
    private func delegationCounter(_ id:String,in app:XCUIApplication) -> XCUIElement {
        let counter=app.descendants(matching:.any).matching(identifier:id).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout:10))
        bringFullyIntoView(counter,in:app)
        XCTAssertTrue(waitForStable(counter,in:app,requireHit:false))
        return counter
    }
    private func counterButton(_ counter:XCUIElement,increase:Bool) -> XCUIElement {
        let buttons=counter.buttons.allElementsBoundByIndex.sorted { $0.frame.midX < $1.frame.midX }
        XCTAssertEqual(buttons.count,2)
        return (increase ? buttons.last : buttons.first) ?? counter.buttons.firstMatch
    }
    private func setDelegationCount(_ id:String,to wanted:Int,in app:XCUIApplication) {
        let counter=delegationCounter(id,in:app)
        guard let initial=Int(counter.value as? String ?? "") else { XCTFail("Missing real counter value");return }
        for number in 0..<abs(wanted-initial) {
            let increasing=wanted>initial,button=counterButton(counter,increase:increasing)
            XCTAssertTrue(button.isEnabled);button.tap()
            let expected=initial+(increasing ? number+1 : -number-1)
            let changed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in counter.value as? String == String(expected) },object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:10),.completed)
        }
        XCTAssertEqual(counter.value as? String,String(wanted))
    }
    private func assertDelegationMaximum(_ id:String,value:Int,in app:XCUIApplication) {
        let counter=delegationCounter(id,in:app),plus=counterButton(counter,increase:true)
        // SwiftUI's native Stepper renders its upper-bound button disabled on
        // iOS26 but still reports isEnabled=true through AX. Verify the actual
        // user action cannot exceed the bound, rather than trusting that flag.
        XCTAssertEqual(counter.value as? String,String(value))
        if plus.isEnabled { plus.tap() }
        XCTAssertEqual(counter.value as? String,String(value))
    }
    private func tapSwitchControl(_ control:XCUIElement,in app:XCUIApplication) {
        XCTAssertEqual(control.elementType,.switch)
        XCTAssertTrue(control.isEnabled)
        let implementation = control.switches.firstMatch
        let rendered = implementation.exists ? implementation : control
        let frame = rendered.frame.intersection(control.frame).intersection(app.frame)
        // No guessed screen point and no direct model/accessibility activation.
        // SwiftUI's whole labelled row is a Switch, but its centre is the label.
        guard !frame.isEmpty,frame.width <= 100,frame.height <= 60 else {
            XCTFail("The rendered switch thumb is not visible");return
        }
        let window = app.frame
        let wasOn = control.value as? String == "1"
        let origin = app.coordinate(withNormalizedOffset:.zero)
        let start = origin.withOffset(CGVector(dx:frame.minX+frame.width*(wasOn ? 0.75 : 0.25)-window.minX,dy:frame.midY-window.minY))
        let end = origin.withOffset(CGVector(dx:frame.minX+frame.width*(wasOn ? 0.25 : 0.75)-window.minX,dy:frame.midY-window.minY))
        print("SWITCH_GESTURE id=\(control.identifier) frame=\(frame) window=\(window) fromOn=\(wasOn)")
        // A List may defer the touch-down while deciding whether to scroll.
        // Hold the real thumb before moving, then release it at the target.
        start.press(forDuration:0.4,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.2)
    }
    @discardableResult private func setAutomationRule(_ symbol:String,to enabled:Bool,in app:XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching:.any).matching(identifier:"automation-rule-"+symbol).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10)); bringIntoView(row,in:app)
        let control = nativeSwitch(row), expected = enabled ? "1" : "0"
        if control.value as? String != expected { tapSwitchControl(control,in:app) }
        // Collapsing an expanded rule rebuilds its AX node and clamps the
        // scroll offset. Read the saved value only after that real reflow.
        XCTAssertTrue(waitForStable(control,in:app,requireHit:false),"Rule did not settle after its content changed")
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in control.value as? String == expected },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:5),.completed)
        return control
    }
    private func bringFullyIntoView(_ element:XCUIElement,in app:XCUIApplication) {
        // Preserve accessibility-tree order across List and ScrollView: a sheet
        // may contain either, while the other type remains behind it. Ignore
        // small nested horizontal pickers when choosing the vertical viewport.
        let scrollTypes = NSPredicate(format:"elementType == %d OR elementType == %d",
            XCUIElement.ElementType.collectionView.rawValue,XCUIElement.ElementType.scrollView.rawValue)
        let window = app.frame
        if element.exists, !element.frame.isEmpty, element.frame.intersects(window) {
            XCTAssertTrue(waitForStable(element,in:app,requireHit:false),"Control moved while the keyboard or sheet was changing")
        }
        for _ in 0..<22 {
            // A keyboard disappearing changes the query's indices. Bind to
            // actual AX elements and resolve the current viewport after every
            // reflow instead of keeping an index into the previous hierarchy.
            let containers = app.descendants(matching:.any).matching(scrollTypes).allElementsBoundByAccessibilityElement
            let container = containers.last { view in
                guard view.exists else { return false }
                let frame = view.frame
                return frame.width >= window.width*0.75 && frame.height >= window.height*0.30
            } ?? app
            let viewport = container.frame.insetBy(dx:0,dy:8)
            let frame = element.exists ? element.frame : .null
            if !frame.isNull,frame.minY >= viewport.minY,frame.maxY <= viewport.maxY { return }
            let down = !frame.isNull && frame.minY < viewport.minY
            container.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.4 : 0.7))
                .press(forDuration:0.05,thenDragTo:container.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:down ? 0.7 : 0.4)))
        }
        XCTFail("Element never became fully visible: " + element.identifier)
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
        reviewCapture("automation-route-drawing",settledBy:draw)
        draw.tap()
        XCTAssertTrue(app.buttons["route-map-save"].isEnabled)
        XCTAssertTrue(app.staticTexts["route-map-count"].label.contains("0"))
        XCTAssertTrue(waitForStable(draw,in:app))
        draw.tap()
        XCTAssertTrue(waitForStable(draw,in:app))
        map.coordinate(withNormalizedOffset:CGVector(dx:0.35,dy:0.40)).press(forDuration:0.1,
            thenDragTo:map.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.60)))
        let count = app.staticTexts["route-map-count"]
        let drawn = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in count.label.contains("1") },object:count)
        XCTAssertEqual(XCTWaiter.wait(for:[drawn],timeout:10),.completed)
        XCTAssertTrue(app.buttons["route-map-save"].isEnabled)
        reviewCapture("automation-route-map",settledBy:app.buttons["route-map-save"])
        let compactMapHeight=map.frame.height
        app.buttons["route-map-expand"].tap()
        let collapse=app.buttons["route-map-collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout:10))
        XCTAssertTrue(waitForStable(collapse,in:app))
        XCTAssertGreaterThan(map.frame.height,compactMapHeight+100)
        XCTAssertTrue(app.staticTexts["route-map-count"].label.contains("1"))
        reviewCapture("automation-route-map-expanded",settledBy:collapse)
        collapse.tap()
        XCTAssertTrue(app.buttons["route-map-save"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["route-map-count"].label.contains("1"))
        XCTAssertTrue(waitForStable(app.buttons["route-map-save"],in:app))
        app.buttons["route-map-save"].tap()
        XCTAssertTrue(route.waitForExistence(timeout:10)); XCTAssertTrue(route.label.contains("1"))
        setAutomationRule("location",to:false,in:app)

        setAutomationRule("wifi",to:true,in:app)
        let modes = app.segmentedControls["automation-wifi-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout:10)); bringIntoView(modes,in:app)
        reviewCapture("automation-wifi-connect",settledBy:modes)
        modes.buttons.element(boundBy:1).tap()
        reviewCapture("automation-wifi-fingerprint",settledBy:modes)
        setAutomationRule("wifi",to:false,in:app)

        setAutomationRule("clock",to:true,in:app)
        let add = app.buttons["automation-time-add"]
        XCTAssertTrue(add.waitForExistence(timeout:10)); bringIntoView(add,in:app); add.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"automation-time-start-0").firstMatch.waitForExistence(timeout:10))
        bringIntoView(add,in:app)
        reviewCapture("automation-time-point",settledBy:add)
        let remove = app.buttons["automation-time-delete-0"]; bringIntoView(remove,in:app); remove.tap()
        let all = app.buttons["automation-combine-all"]; bringIntoView(all,in:app); all.tap()
        bringIntoView(add,in:app); add.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"automation-time-end-0").firstMatch.waitForExistence(timeout:10))
        bringIntoView(add,in:app)
        reviewCapture("automation-time-interval",settledBy:add)
        setAutomationRule("clock",to:false,in:app)
    }
    func testLogoMenuProvidesLanguageHelpAndWebsiteWithoutOpeningExternalContent() {
        let app = launch("mixed-objects")
        app.buttons["header-menu"].tap()
        let help = app.buttons["header-help"]
        XCTAssertTrue(help.waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["header-website"].exists)
        XCTAssertTrue(app.buttons["header-language"].exists)
        reviewCapture("header-menu",settledBy:help)
        help.tap()
        XCTAssertTrue(app.staticTexts["Как пользоваться приложением"].waitForExistence(timeout:10))
        assertBottom(app,["control","settings","guests","journal"])
        let privacy = app.descendants(matching:.any).matching(identifier:"privacy-policy").firstMatch
        bringFullyIntoView(privacy,in:app)
        XCTAssertTrue(privacy.isHittable); XCTAssertTrue(privacy.label.contains("Политика конфиденциальности"))
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["header-menu"].tap(); app.buttons["header-language"].tap(); app.buttons["Deutsch"].tap()
        XCTAssertTrue(app.buttons["header-menu"].waitForExistence(timeout:10)); app.buttons["header-menu"].tap()
        XCTAssertEqual(app.buttons["header-help"].label,"Hilfe")
        app.buttons["header-language"].tap(); app.buttons["Русский"].tap()
        XCTAssertTrue(app.buttons["main-tab-settings"].waitForExistence(timeout:10))
    }

    func testEnglishKeyImportMessagesAndPrivacyUseSelectedLanguageWithoutOpeningExternalContent() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two","empty","-AppleLanguages","(en)","-AppleLocale","en_US","-entrixy.language","en"]
        app.launch(); activeApp = app
        XCTAssertTrue(app.buttons["main-tab-settings"].waitForExistence(timeout:20))
        app.segmentedControls.buttons["Keys"].tap()
        XCTAssertTrue(app.staticTexts["No received keys yet"].waitForExistence(timeout:10))
        app.buttons["Add key"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"inviteInput").firstMatch.waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["Paste link"].exists)
        XCTAssertTrue(app.buttons["Scan QR code"].exists)
        XCTAssertTrue(app.buttons["Choose QR code from Photos"].exists)
        XCTAssertFalse(app.buttons["Вставить ссылку"].exists)
        app.buttons["Cancel"].tap()
        app.segmentedControls.buttons["System"].tap()
        let messages = app.buttons["Messages"]
        bringFullyIntoView(messages,in:app); messages.tap()
        XCTAssertTrue(app.staticTexts["No messages yet"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Incoming"].exists)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.segmentedControls.buttons["System"].isSelected)
        let privacy = app.descendants(matching:.any).matching(identifier:"privacy-policy").firstMatch
        bringFullyIntoView(privacy,in:app)
        XCTAssertTrue(privacy.isHittable); XCTAssertTrue(privacy.label.contains("Privacy policy"))
        assertBottom(app,["settings","journal"])
    }
    func testGuestPhoneRequestOffersExplicitCallAndDeclineWithoutTelephoneHandoff() {
        let app = XCUIApplication()
        app.launchArguments = ["--stage-two","owner-phone-request","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch(); activeApp = app
        let call = app.buttons["owner-phone-approve"], decline = app.buttons["owner-phone-decline"]
        XCTAssertTrue(call.waitForExistence(timeout:15)); XCTAssertEqual(call.label,"Позвонить")
        XCTAssertTrue(decline.isHittable)
        let description=app.staticTexts["owner-phone-request-description"]
        XCTAssertTrue(description.label.contains("Анна"));XCTAssertTrue(description.label.contains("Ворота во двор"))
        XCTAssertTrue(app.images["owner-phone-object-image"].exists)
        XCTAssertTrue(app.staticTexts["Позвонить?"].exists)
        reviewCapture("guest-call-request",settledBy:call)
        decline.tap()
        XCTAssertTrue(app.buttons["main-tab-journal"].waitForExistence(timeout:10)); app.buttons["main-tab-journal"].tap()
        XCTAssertTrue(app.staticTexts["Журнал пуст. Здесь будут появляться вызовы."].waitForExistence(timeout:10))
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
        let actions=["gearshape","plus","qrcode","share","envelope","pause.fill","trash"].map { app.buttons["guest-action-"+$0] }
        for button in actions { XCTAssertEqual(button.frame.width,48,accuracy:1);XCTAssertEqual(button.frame.height,48,accuracy:1) }
        XCTAssertEqual((actions[5].frame.midX+actions[6].frame.midX)/2,row.frame.midX,accuracy:1)
        reviewCapture("guest-issued-actions",settledBy:app.buttons["issue-guest"])
        app.buttons["Изменить"].tap()
        XCTAssertTrue(app.textFields.matching(NSPredicate(format:"value == %@","Анна")).firstMatch.waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["Сохранить"].exists)
        reviewCapture("guest-issued-edit")
        app.buttons["Отмена"].tap(); XCTAssertTrue(row.waitForExistence(timeout:10))
        app.buttons["QR"].tap()
        XCTAssertTrue(app.staticTexts["task-sheet-title"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["task-sheet-title"].label,"QR")
        XCTAssertTrue(app.buttons["Копировать"].exists)
        let image = app.images["QR-код гостевого ключа"]
        XCTAssertTrue(image.exists); XCTAssertGreaterThan(image.frame.width,200)
        XCTAssertTrue(app.buttons["Закрыть"].isHittable)
        reviewCapture("guest-issued-qr",settledBy:app.buttons["Закрыть"])
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
        let save = app.buttons["backup-save-file"], send = app.buttons["backup-share-file"], cancel = app.buttons["Отмена"]
        XCTAssertFalse(save.isEnabled);XCTAssertFalse(send.isEnabled);XCTAssertTrue(cancel.isEnabled)
        XCTAssertEqual(save.frame.height,send.frame.height,accuracy:1)
        XCTAssertEqual(save.frame.width,send.frame.width,accuracy:1)
        XCTAssertGreaterThanOrEqual(send.frame.minY,save.frame.maxY)
        XCTAssertGreaterThanOrEqual(cancel.frame.minY,send.frame.maxY)
        reviewCapture("backup-password",settledBy:cancel)
        let password=app.secureTextFields["Пароль копии"],repeated=app.secureTextFields["Повторите пароль"]
        let enteredPassword="native-review-only"
        password.tap();password.typeText(enteredPassword)
        XCTAssertEqual((password.value as? String)?.count,enteredPassword.count)
        password.typeText("\n")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(waitForStable(repeated,in:app));repeated.tap()
        repeated.typeText(enteredPassword)
        XCTAssertEqual((repeated.value as? String)?.count,enteredPassword.count)
        repeated.typeText("\n")
        XCTAssertTrue(waitForStable(cancel,in:app))
        XCTAssertTrue(save.isEnabled);XCTAssertTrue(send.isEnabled);XCTAssertTrue(cancel.isEnabled)
        reviewCapture("backup-password-ready",settledBy:cancel)
        app.buttons["Отмена"].tap()
        assertBottom(app,["settings","journal"])
    }
    func testHomeNetworkConsentAndRemovalUseSystemSectionAndPreserveReceivedKeys() {
        let app = launch("network-privacy")
        let row = app.descendants(matching:.any).matching(identifier:"privacy-cellular-consent").firstMatch
        bringIntoView(row,in:app)
        XCTAssertTrue(row.waitForExistence(timeout:5))
        let toggle = nativeSwitch(row)
        XCTAssertTrue(toggle.exists); XCTAssertTrue(toggle.isEnabled); XCTAssertEqual(toggle.value as? String,"0")
        reviewCapture("home-network",settledBy:toggle)
        tapSwitchControl(toggle,in:app)
        XCTAssertTrue(waitForStable(toggle,in:app,requireHit:false))
        let enabled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in toggle.value as? String == "1" },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:5),.completed)
        let remove = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","privacy-remove-")).firstMatch
        bringIntoView(remove,in:app)
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
        bringIntoView(row,in:app)
        XCTAssertEqual(control.value as? String,"0"); tapSwitchControl(control,in:app)
        XCTAssertTrue(waitForStable(control,in:app,requireHit:false))
        let enabled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in control.value as? String == "1" },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:5),.completed)
        XCTAssertFalse(app.buttons["diagnostics-send"].exists)
        reviewCapture("diagnostic-settings")
        app.buttons["header-menu"].tap()
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
        bringFullyIntoView(send,in:app)
        XCTAssertTrue(send.isHittable); send.tap()
        let sent = app.staticTexts["Технический журнал отправлен."]
        bringFullyIntoView(sent,in:app)
        XCTAssertTrue(sent.waitForExistence(timeout:10))
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
        XCTAssertTrue(app.textFields["Название"].waitForExistence(timeout:20))
        bringFullyIntoView(code,in:app)
        XCTAssertTrue(code.waitForExistence(timeout:20)); XCTAssertEqual(code.value as? String,"A1B2C3D4")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","factory.invalid:8443")).firstMatch.exists)
        reviewCapture("device-claim",settledBy:code)
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
        XCTAssertTrue(waitForStable(lifetime,in:app))
        // iOS26 SwiftUI exposes this discrete slider as raw 0...10 ("5"),
        // rather than a percentage. XCTest's normalized adjust synthesized a
        // gesture without moving the actual thumb in the failed source916 run.
        // Drag the visible thumb from its reported value; keep the value-change
        // assertion and require the real one-hour setting afterwards.
        let raw = lifetime.value as? String ?? ""
        let number = Double(raw.replacingOccurrences(of:"%",with:"")) ?? .nan
        let normalized = raw.contains("%") ? number/100 : number/10
        XCTAssertTrue(normalized.isFinite && (0...1).contains(normalized))
        let frame = lifetime.frame.intersection(app.frame), inset = frame.height/2
        XCTAssertTrue(frame.width > 2*inset && frame.height > 0)
        let origin = app.coordinate(withNormalizedOffset:.zero)
        let start = origin.withOffset(CGVector(dx:frame.minX+inset+(frame.width-2*inset)*CGFloat(normalized)-app.frame.minX,dy:frame.midY-app.frame.minY))
        let end = origin.withOffset(CGVector(dx:frame.minX+inset-app.frame.minX,dy:frame.midY-app.frame.minY))
        start.press(forDuration:0.4,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.2)
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in value.label != previous },object:value)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:5),.completed)
        XCTAssertEqual(value.label,"1 час")
        reviewCapture("guest-ble-lifetime",settledBy:lifetime)
        app.buttons["Закрыть"].tap(); app.buttons["Отмена"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-card-")).firstMatch.exists)
    }
    func testGuestNestedBackAndRootSwitch() {
        let app = launch("guest-keys")
        assertBottom(app, ["control", "settings", "journal"])
        let key = app.descendants(matching:.any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "received-key-")).firstMatch
        let trash = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","received-key-delete-")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5)); XCTAssertTrue(trash.isHittable)
        XCTAssertFalse(app.buttons["Обновить данные"].exists)
        reviewCapture("received-key-list",settledBy:trash)
        trash.tap()
        XCTAssertTrue(app.staticTexts["Удалить ключ?"].waitForExistence(timeout:5))
        let cancel = app.buttons["dialog-cancel"], remove = app.buttons["dialog-confirm"]
        XCTAssertTrue(cancel.isHittable); XCTAssertTrue(remove.isHittable)
        XCTAssertEqual(cancel.frame.height,remove.frame.height,accuracy:1)
        reviewCapture("received-key-delete-confirmation")
        cancel.tap()
        XCTAssertTrue(trash.waitForExistence(timeout:5))
        assertBottom(app, ["control", "settings", "journal"])
        trash.tap(); remove.tap()
        XCTAssertTrue(app.staticTexts["received-keys-empty"].waitForExistence(timeout:10))
        XCTAssertFalse(trash.exists)
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
        XCTAssertTrue(waitForStable(field,in:app))
        let old = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        let cleared = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            let value = field.value as? String
            return value == "" || value == placeholder
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[cleared],timeout:5),.completed)
        field.typeText("Yard")
        let entered = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in field.value as? String == "Yard" },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[entered],timeout:5),.completed)
        field.typeText("\n")
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
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "received-key-")).firstMatch.waitForExistence(timeout: 10))
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
        app.buttons["main-tab-settings"].tap()
        XCTAssertFalse(app.buttons["Править"].exists)
        let handles = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","object-drag-"))
        XCTAssertEqual(handles.count,3)
        handles.element(boundBy:0).press(forDuration:1.2,thenDragTo:handles.element(boundBy:2))
        let reordered = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in row("Дверь Bluetooth").frame.minY > row("Гостевой въезд").frame.minY },object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[reordered],timeout:8),.completed)
        app.buttons["main-tab-control"].tap()
        XCTAssertLessThan(card("Гостевой въезд").frame.minY,card("Дверь Bluetooth").frame.minY)
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
        XCTAssertTrue(app.staticTexts["owner-object-title"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["owner-object-title"].label,"Редактировать объект")
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
    }
    func testObjectCameraSettingsStayInsideEditorWhileScrolling() {
        let app=launch("owner-expanded")
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","object-edit-owner:")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["owner-object-title"].waitForExistence(timeout:10))
        let camera = app.descendants(matching:.any).matching(identifier:"object-camera-enabled").firstMatch
        bringIntoView(camera,in:app); tapSwitchControl(nativeSwitch(camera),in:app)
        let address = app.textFields["object-camera-url"]
        XCTAssertTrue(address.waitForExistence(timeout:10))
        // Scroll the actual Form viewport until its last option is visible;
        // screen-relative swipes could start on the sheet's cancellation footer.
        let nearby=app.buttons["camera-show-nearby"]
        bringIntoView(nearby,in:app)
        XCTAssertTrue(app.staticTexts["owner-object-title"].exists)
        XCTAssertTrue(nearby.isHittable)
        reviewCapture("object-camera-settings",settledBy:nearby)
    }

    func testCallGuestPreferencesAndDeviceAccessUseActualEditorsWithoutIssuingOrConnecting() {
        let app = launch("owner-call-guests")
        app.buttons["issue-guest"].tap()
        let object = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-object-owner:")).firstMatch
        XCTAssertTrue(object.waitForExistence(timeout:10)); object.tap()
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","guest-object-invocation-")).firstMatch.tap()
        let reaction = app.descendants(matching:.any).matching(identifier:"guest-call-enabled").firstMatch
        XCTAssertTrue(reaction.waitForExistence(timeout:10))
        bringIntoView(reaction,in:app)
        if nativeSwitch(reaction).value as? String != "1" { tapSwitchControl(nativeSwitch(reaction),in:app) }
        let policy = app.staticTexts["guest-call-confirmation-policy"]
        XCTAssertTrue(policy.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["guest-call-reaction-auto"].exists)
        XCTAssertFalse(app.buttons["guest-call-reaction-notify"].exists)
        XCTAssertFalse(app.staticTexts["Во время разговора"].exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"guest-call-notification").firstMatch.exists)
        XCTAssertTrue(policy.label.hasPrefix("Каждый запрос гостя"))
        XCTAssertTrue(app.buttons["Закрыть"].isHittable)
        reviewCapture("guest-call-preferences",settledBy:app.buttons["Закрыть"])
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
        XCTAssertGreaterThan(avatarUpload.frame.minY,avatarCancel.frame.maxY)
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
        for prefix in ["guest-object-invocation-","guest-object-automation-","guest-object-access-"] {
            let action=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@",prefix)).firstMatch
            XCTAssertEqual(action.frame.width,48,accuracy:1);XCTAssertEqual(action.frame.height,48,accuracy:1)
        }
        XCTAssertFalse(app.switches["Подтверждать нажатие перед открытием"].exists)
        reviewCapture("guest-issue-object")
        app.buttons["Автоматизация для гостя"].tap()
        XCTAssertTrue(app.staticTexts["Условия"].waitForExistence(timeout: 10))
        reviewCapture("automation-guest")
        app.buttons["Закрыть"].tap()
        app.buttons["Доступ к объекту"].tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Только для приложения")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Разрешить передавать дальше")).firstMatch.exists)
        let delegation=app.descendants(matching:.any).matching(identifier:"delegation-enabled").firstMatch
        bringIntoView(delegation,in:app);tapSwitchControl(nativeSwitch(delegation),in:app)
        setDelegationCount("delegation-depth",to:3,in:app)
        setDelegationCount("delegation-pool",to:7,in:app)
        reviewCapture("guest-access-limits")
        let ok=app.buttons["ОК"].firstMatch;bringIntoView(ok,in:app);ok.tap()
        app.buttons["Доступ к объекту"].tap()
        XCTAssertEqual(delegationCounter("delegation-depth",in:app).value as? String,"3")
        XCTAssertEqual(delegationCounter("delegation-pool",in:app).value as? String,"7")
        bringIntoView(ok,in:app);ok.tap()
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

    func testDelegatedAccessShowsSeveralLevelsAndPoolWithoutCreatingKey() {
        let app=launch("delegating-guests-deep")
        app.buttons["pass-received-access"].tap()
        let object=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","pass-object-")).firstMatch
        XCTAssertTrue(object.waitForExistence(timeout:10));object.tap()
        app.buttons["Настройки доступа"].tap()
        XCTAssertFalse(app.switches.matching(NSPredicate(format:"label CONTAINS %@","Только для приложения")).firstMatch.exists)
        let enabled=app.descendants(matching:.any).matching(identifier:"delegation-enabled").firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout:10));bringIntoView(enabled,in:app)
        tapSwitchControl(nativeSwitch(enabled),in:app)
        // Incoming depth4/pool12 permits at most3 further levels and11 child keys.
        setDelegationCount("delegation-depth",to:3,in:app)
        assertDelegationMaximum("delegation-depth",value:3,in:app)
        setDelegationCount("delegation-pool",to:11,in:app)
        assertDelegationMaximum("delegation-pool",value:11,in:app)
        setDelegationCount("delegation-pool",to:7,in:app)
        reviewCapture("passed-access-delegation-limits")
        let ok=app.buttons["ОК"].firstMatch;bringIntoView(ok,in:app);ok.tap()
        app.buttons["Настройки доступа"].tap()
        XCTAssertEqual(delegationCounter("delegation-depth",in:app).value as? String,"3")
        XCTAssertEqual(delegationCounter("delegation-pool",in:app).value as? String,"7")
        bringIntoView(ok,in:app);ok.tap();app.buttons["Отмена"].tap()
        assertBottom(app,["control","settings","guests","journal"])
    }

    func testServerRowsAndCompactAccountDialogStayInSystemAndCancelWithoutRegistration() {
        let app = launch("empty")
        app.segmentedControls.buttons["Система"].tap()
        let existing = app.buttons["server-select-entrixy.com"]
        bringFullyIntoView(existing,in:app)
        XCTAssertTrue(existing.waitForExistence(timeout:10))
        let add = app.buttons["server-add"]
        bringFullyIntoView(add,in:app)
        XCTAssertTrue(add.isHittable)
        add.tap()
        let host = app.textFields["server-host"]
        XCTAssertTrue(host.waitForExistence(timeout:10)); XCTAssertTrue(host.isEnabled)
        XCTAssertTrue(app.textFields["Почта"].exists); XCTAssertTrue(app.secureTextFields["Пароль"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Отмена"].exists)
        let cancel = app.buttons["Отмена"]
        reviewCapture("server-account",settledBy:cancel)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(app.frame.insetBy(dx:0,dy:1).contains(cancel.frame))
        cancel.tap()
        XCTAssertTrue(add.waitForExistence(timeout:10)); assertBottom(app,["settings","journal"])
    }

    func testLocalResetRequiresTypedConfirmationAndDoesNotExposeOldAccess() {
        let app = launch("empty")
        app.segmentedControls.buttons["Система"].tap()
        let open = app.buttons["local-reset-open"]
        bringFullyIntoView(open,in:app); XCTAssertTrue(open.isHittable); open.tap()
        let confirmation = app.textFields["local-reset-confirmation"], erase = app.buttons["local-reset-erase"]
        XCTAssertTrue(confirmation.waitForExistence(timeout:10)); XCTAssertFalse(erase.isEnabled)
        let cancel = app.buttons["Отмена"]
        reviewCapture("local-reset-confirmation",settledBy:cancel)
        cancel.tap(); XCTAssertTrue(open.waitForExistence(timeout:10)); open.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout:10))
        confirmation.tap(); confirmation.typeText("RESET\n")
        bringFullyIntoView(erase,in:app); XCTAssertTrue(erase.isEnabled); XCTAssertTrue(erase.isHittable); erase.tap()
        let restart = app.buttons["local-reset-restart"]
        XCTAssertTrue(restart.waitForExistence(timeout:15)); XCTAssertTrue(app.staticTexts["local-reset-complete"].exists)
        XCTAssertTrue(restart.isEnabled)
        XCTAssertFalse(confirmation.exists); XCTAssertFalse(app.buttons["Отмена"].exists)
        reviewCapture("local-reset-complete",settledBy:restart)
    }

    func testServerDeletionRequiresConfirmationAndReportsPendingWithoutClaimingErasure() {
        let app = launch("data-deletion")
        let open = app.buttons["data-deletion-settings"]
        bringFullyIntoView(open,in:app); XCTAssertTrue(open.isHittable); open.tap()
        let server = app.buttons["data-deletion-server-controller.invalid"]
        XCTAssertTrue(server.waitForExistence(timeout:10))
        XCTAssertTrue(waitForStable(server,in:app)); server.tap()
        let field = app.textFields["data-deletion-confirmation"], submit = app.buttons["data-deletion-submit"]
        XCTAssertTrue(field.waitForExistence(timeout:10)); XCTAssertFalse(submit.isEnabled)
        bringFullyIntoView(submit,in:app)
        reviewCapture("server-deletion-confirmation",settledBy:app.buttons["Отмена"])
        let password = app.secureTextFields["data-deletion-password"]
        let enteredPassword = "review-only-password"
        bringFullyIntoView(password,in:app); password.tap(); password.typeText(enteredPassword)
        XCTAssertEqual((password.value as? String)?.count,enteredPassword.count,"The secure field must retain every typed password character")
        bringFullyIntoView(field,in:app); field.tap(); field.typeText("DELETE\n")
        bringFullyIntoView(submit,in:app); XCTAssertTrue(submit.isEnabled); submit.tap()
        let status = app.staticTexts["data-deletion-status"]
        XCTAssertTrue(status.waitForExistence(timeout:15)); XCTAssertTrue(status.label.contains("ещё"))
        reviewCapture("server-deletion-pending",settledBy:app.buttons["Закрыть"])
        app.buttons["Закрыть"].tap(); XCTAssertTrue(server.waitForExistence(timeout:10))
        assertBottom(app,["control","settings","guests","journal"])
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
            tapSwitchControl(thumb,in:app)
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
