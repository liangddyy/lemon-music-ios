import XCTest

final class LemonMusicUITests: XCTestCase {
    func testCollectionActionsSearchAndPlaybackModes() {
        let app = fixtures()
        for _ in 0..<3 where !app.staticTexts["我的精选"].firstMatch.isHittable { app.swipeUp() }
        app.staticTexts["我的精选"].tap()
        XCTAssertTrue(app.buttons["collection.playAll"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["collection.nas"].isHittable)
        XCTAssertTrue(app.buttons["collection.cache"].isHittable)
        XCTAssertFalse(app.buttons["collection.favorite"].exists)
        attachment(app, name: "collection-light")
        app.buttons["collection.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("not-found")
        XCTAssertTrue(app.staticTexts["没有找到结果"].waitForExistence(timeout: 3))
        let closeSearch = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel", "取消", "关闭"])).firstMatch
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 3))
        closeSearch.tap()
        app.buttons["collection.playAll"].tap()
        let miniPlayer = app.buttons["miniPlayer.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        miniPlayer.tap()
        let mode = app.buttons["player.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.value as? String, "顺序播放")
        mode.tap()
        XCTAssertEqual(mode.value as? String, "随机播放")
        mode.tap()
        XCTAssertEqual(mode.value as? String, "单曲循环")
        mode.tap()
        XCTAssertEqual(mode.value as? String, "顺序播放")
        attachment(app, name: "player-light")
        let slider = app.sliders.firstMatch
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).press(
            forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        )
        XCTAssertTrue(mode.exists)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.25))
        edge.press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.25)),
            withVelocity: .slow, thenHoldForDuration: 1
        )
        XCTAssertTrue(mode.exists)
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.25)))
        XCTAssertTrue(app.buttons["collection.playAll"].waitForExistence(timeout: 5))
        XCTAssertFalse(mode.exists)
        XCTAssertTrue(app.buttons["暂停"].exists)
    }

    func testOnlineCollectionFavoriteAndNASOptionsInDarkMode() {
        let app = fixtures(extra: ["-uiTestingDark"])
        app.tabBars.buttons["发现"].tap()
        XCTAssertFalse(app.staticTexts["新碟"].exists)
        app.staticTexts["午后音乐"].firstMatch.tap()
        let favorite = app.buttons["collection.favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.label, "取消收藏歌单")
        attachment(app, name: "collection-dark")
        app.buttons["collection.nas"].tap()
        XCTAssertTrue(app.buttons["collection.nas.confirm"].waitForExistence(timeout: 5))
        attachment(app, name: "nas-options")
        app.buttons["取消"].firstMatch.tap()
        favorite.tap()
        app.buttons["取消收藏"].tap()
        XCTAssertTrue(app.staticTexts["推荐歌单"].waitForExistence(timeout: 5))
    }

    func testLargeTypeCollectionActionsRemainReachable() {
        let app = fixtures(extra: ["-uiTestingLargeType"])
        for _ in 0..<3 where !app.staticTexts["我的精选"].firstMatch.isHittable { app.swipeUp() }
        app.staticTexts["我的精选"].firstMatch.tap()
        XCTAssertTrue(app.buttons["collection.playAll"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["collection.nas"].exists)
        XCTAssertTrue(app.buttons["collection.cache"].exists)
        attachment(app, name: "collection-large-type")
    }

    private func fixtures(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingFixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 10))
        return app
    }

    private func attachment(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLaunchesToVisibleInterface() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testRealServerLoginWhenCredentialsAreProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["LEMON_TEST_SERVER"],
              let username = environment["LEMON_TEST_USERNAME"],
              let password = environment["LEMON_TEST_PASSWORD"] else {
            throw XCTSkip("未提供真实服务器测试环境变量")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingReset"]
        app.launch()

        let serverField = app.textFields["服务器地址"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        serverField.tap()
        serverField.typeText(server)

        let usernameField = app.textFields["用户名"]
        usernameField.tap()
        usernameField.typeText(username)

        let passwordField = app.secureTextFields["密码"]
        passwordField.tap()
        passwordField.typeText(password)

        app.buttons["登录"].tap()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 30))
    }
}
