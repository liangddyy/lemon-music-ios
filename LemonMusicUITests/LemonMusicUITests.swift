import XCTest

final class LemonMusicUITests: XCTestCase {
    func testPausedPlayerSliderSupportsAccessibilityAdjustment() {
        let app = fixtures()
        app.buttons["track.play.local:/fixtures/0.wav"].firstMatch.tap()
        XCTAssertTrue(app.buttons["miniPlayer.open"].waitForExistence(timeout: 5))
        app.buttons["miniPlayer.open"].tap()
        let slider = app.sliders["player.progress"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == YES"), evaluatedWith: slider)
        waitForExpectations(timeout: 10)
        let playPause = app.buttons["player.playPause"]
        if playPause.label == "暂停" { playPause.tap() }
        XCTAssertEqual(playPause.label, "播放")
        slider.adjust(toNormalizedSliderPosition: 0.65)
        Thread.sleep(forTimeInterval: 0.8)
        let raw = slider.value as? String ?? ""
        let number = Double(raw.replacingOccurrences(of: "%", with: "")) ?? 0
        let seconds = raw.contains("%") ? number / 100 * 20 : number
        XCTAssertGreaterThan(seconds, 10)
        XCTAssertLessThan(seconds, 15)
        XCTAssertEqual(playPause.label, "播放")
        attachment(app, name: "paused-player-seek")
    }

    func testCachePreferencesUpdateImmediatelyAndSurviveRelaunch() {
        let app = fixtures(extra: ["-uiTestingPersistentPlayback", "-uiTestingResetPlayback"])
        app.buttons["设置"].tap()
        let automatic = app.switches["settings.automaticCache"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertEqual(automatic.value as? String, "0")
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(automatic.value as? String, "1")
        let limit = app.buttons["settings.cacheLimit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        limit.tap()
        app.buttons["1 GB"].tap()
        XCTAssertTrue(limit.label.contains("1 GB"))
        attachment(app, name: "cache-preferences")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestingResetPlayback" }
        app.launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        app.buttons["设置"].tap()
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertEqual(automatic.value as? String, "1")
        XCTAssertTrue(limit.label.contains("1 GB"))
    }

    func testSearchDefaultsOnlineAndRemembersScopeAcrossTabs() {
        let app = fixtures()
        tabButton("搜索", in: app.tabBars.firstMatch).tap()
        let online = app.segmentedControls.firstMatch.buttons["在线"]
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        XCTAssertTrue(online.isSelected)
        app.segmentedControls.firstMatch.buttons["音乐库"].tap()
        app.tabBars.buttons["首页"].tap()
        tabButton("搜索", in: app.tabBars.firstMatch).tap()
        XCTAssertTrue(app.segmentedControls.firstMatch.buttons["音乐库"].isSelected)
        attachment(app, name: "search-remembers-scope")
    }

    func testPlayerDownloadSeparatesNASAndPhoneCache() {
        let app = fixtures()
        app.buttons["track.play.local:/fixtures/0.wav"].firstMatch.tap()
        XCTAssertTrue(app.buttons["miniPlayer.open"].waitForExistence(timeout: 5))
        app.buttons["miniPlayer.open"].tap()
        let download = app.buttons["player.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.isHittable)
        download.tap()
        XCTAssertTrue(app.buttons["download.cache"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["download.nas"].isEnabled)
        XCTAssertTrue(app.staticTexts["已在 NAS 音乐库"].exists)
        attachment(app, name: "single-track-download")
    }

    func testMiniPlayerStaysAboveTabBarAcrossTabsAndNavigation() {
        let app = fixtures()
        let miniPlayer = app.buttons["miniPlayer.open"]
        let tabBar = app.tabBars.firstMatch
        for title in ["首页", "发现", "音乐库", "搜索"] {
            XCTAssertTrue(tabButton(title, in: tabBar).isHittable)
        }
        XCTAssertFalse(miniPlayer.exists)
        attachment(app, name: "tabs-without-player")
        app.buttons["track.play.local:/fixtures/0.wav"].firstMatch.tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))

        for title in ["发现", "音乐库", "搜索", "首页"] {
            XCTAssertLessThanOrEqual(miniPlayer.frame.maxY, tabBar.frame.minY)
            let button = tabButton(title, in: tabBar)
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
            XCTAssertLessThanOrEqual(miniPlayer.frame.maxY, tabBar.frame.minY)
            if title == "搜索" {
                XCTAssertTrue(app.navigationBars["搜索"].exists)
                // Newer systems replace the selected search tab with a search field.
                if !tabBar.buttons["首页"].exists { tabBar.buttons["音乐库"].tap() }
            } else {
                XCTAssertTrue(button.isSelected)
            }
        }
        attachment(app, name: "mini-player-above-tabs")
        for _ in 0..<3 where !app.staticTexts["我的精选"].firstMatch.isHittable { app.swipeUp() }
        app.staticTexts["我的精选"].firstMatch.tap()
        XCTAssertTrue(app.buttons["collection.playAll"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(miniPlayer.frame.maxY, tabBar.frame.minY)
        attachment(app, name: "mini-player-above-tabs-in-playlist")
        miniPlayer.tap()
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 5))
        app.buttons["player.close"].tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(miniPlayer.frame.maxY, tabBar.frame.minY)
        XCTAssertTrue(tabBar.buttons["发现"].isHittable)
    }

    private func tabButton(_ title: String, in tabBar: XCUIElement) -> XCUIElement {
        if title == "搜索" {
            return tabBar.buttons.matching(NSPredicate(format: "label IN %@", ["搜索", "Search"])).firstMatch
        }
        return tabBar.buttons[title]
    }

    func testCacheClearRequiresConfirmationAndRefreshesUsage() {
        let app = fixtures()
        app.buttons["设置"].tap()
        let clear = app.buttons["settings.clearAudioCache"]
        for _ in 0..<3 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let usage = app.staticTexts["settings.audioCacheUsed"]
        XCTAssertTrue(usage.exists)
        let originalUsage = usage.label
        XCTAssertFalse(originalUsage.hasSuffix(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)))
        clear.tap()
        XCTAssertTrue(app.alerts["清空音频缓存？"].waitForExistence(timeout: 3))
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(usage.label, originalUsage)
        XCTAssertFalse(app.staticTexts["settings.cacheClearResult"].exists)
        clear.tap()
        app.alerts.buttons["清空"].tap()
        let zeroUsage = NSPredicate(format: "label ENDSWITH %@", ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        expectation(for: zeroUsage, evaluatedWith: usage)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["音频缓存已清空"].exists)
        attachment(app, name: "cache-cleared-refreshed")
        app.buttons["完成"].tap()
        app.buttons["设置"].tap()
        for _ in 0..<3 where !usage.isHittable { app.swipeUp() }
        XCTAssertTrue(usage.label.hasSuffix(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)))
    }

    func testRestoredMiniPlayerActuallyPlaysAfterAppRelaunch() {
        let app = fixtures(extra: ["-uiTestingPersistentPlayback", "-uiTestingResetPlayback"])
        for _ in 0..<3 where !app.staticTexts["我的精选"].firstMatch.isHittable { app.swipeUp() }
        app.staticTexts["我的精选"].tap()
        app.buttons["collection.playAll"].tap()
        XCTAssertTrue(app.buttons["miniPlayer.open"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestingResetPlayback" }
        app.launch()
        let miniPlayer = app.buttons["miniPlayer.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 10))
        miniPlayer.tap()
        let button = app.buttons["player.playPause"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(button.label, "播放")
        button.tap()
        let playing = NSPredicate(format: "label == %@", "暂停")
        expectation(for: playing, evaluatedWith: button)
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(button.label, "暂停")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "player.error").firstMatch.exists)
        attachment(app, name: "restored-playback")
        app.buttons["player.close"].tap()
    }

    func testDataSaverSettingDefaultsOnAndHasNASScopeDescription() {
        let app = fixtures()
        app.buttons["设置"].tap()
        let toggle = app.switches["settings.dataSaver"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(toggle.value as? String, "0")
        attachment(app, name: "data-saver-settings")
        app.buttons["完成"].tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["完成"].tap()
    }

    func testLyricsFillAreaAboveProgressAndHideTrackMetadata() {
        let app = fixtures()
        for _ in 0..<3 where !app.staticTexts["我的精选"].firstMatch.isHittable { app.swipeUp() }
        app.staticTexts["我的精选"].tap()
        app.buttons["collection.playAll"].tap()
        XCTAssertTrue(app.buttons["miniPlayer.open"].waitForExistence(timeout: 5))
        app.buttons["miniPlayer.open"].tap()
        let media = app.descendants(matching: .any).matching(identifier: "player.media").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.swipeLeft()
        let lyrics = app.descendants(matching: .any).matching(identifier: "player.lyrics").firstMatch
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "player.trackInfo").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "player.cacheStatus").firstMatch.exists)
        let progress = app.sliders["player.progress"]
        XCTAssertTrue(progress.exists)
        XCTAssertGreaterThan(lyrics.frame.height, 400)
        XCTAssertGreaterThan(lyrics.frame.width, app.frame.width * 0.8)
        XCTAssertLessThanOrEqual(lyrics.frame.maxY, progress.frame.minY + 2)
        attachment(app, name: "lyrics-full-area")
        lyrics.swipeRight()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "player.trackInfo").firstMatch.waitForExistence(timeout: 3))
        app.buttons["player.close"].tap()
    }

    func testCollectionActionsSearchAndPlaybackModes() {
        let app = fixtures()
        for _ in 0..<3 where !app.staticTexts["我的精选"].firstMatch.isHittable { app.swipeUp() }
        app.staticTexts["我的精选"].tap()
        XCTAssertTrue(app.buttons["collection.playAll"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["collection.nas"].isHittable)
        XCTAssertTrue(app.buttons["collection.cache"].isHittable)
        XCTAssertFalse(app.buttons["collection.favorite"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
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
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["track.play.local:/fixtures/0.wav"].exists)
        XCTAssertTrue(app.buttons["track.play.local:/fixtures/1.wav"].exists)
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
