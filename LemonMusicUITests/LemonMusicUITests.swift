import XCTest

final class LemonMusicUITests: XCTestCase {
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
