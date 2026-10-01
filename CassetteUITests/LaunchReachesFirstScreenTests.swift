// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import XCTest

/// Guards the launch path end to end: the app must get past the loading spinner to a real screen.
///
/// The launch runs in `AppLauncher`, outside the window. If the container were never handed back to
/// the window, the app would sit on `ProgressView` forever and every unit test would still pass.
/// Which screen appears depends on the simulator's state (onboarding on a fresh one, the tab view
/// once a server is set up), so either counts.
final class LaunchReachesFirstScreenTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchReachesOnboardingOrMainScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let firstScreen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["root.onboarding", "root.main"]))
            .firstMatch
        // An upper bound on the UI appearing, not a delay: the wait returns as soon as it does.
        XCTAssertTrue(firstScreen.waitForExistence(timeout: 30), "Launch never got past the loading screen")
    }
}
