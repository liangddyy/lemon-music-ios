// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Cassette

// Locks the shared launch. The window and, from v2.0, the CarPlay scene both ask for the container,
// and either can come first: the sequence must run once per process however many scenes ask, keep its
// order, and keep reacting to connectivity now that no view's `.task(id:)` does it.

/// Records which launch steps ran, and how many containers were built.
@MainActor
private final class LaunchRecorder {
    var events: [String] = []
    var containersBuilt = 0
    var networkRestoredCount = 0

    func steps() -> AppLaunchSteps {
        AppLaunchSteps(
            prepare: { _ in self.events.append("prepare") },
            restore: { _ in self.events.append("restore") },
            background: { _ in self.events.append("background") },
            networkRestored: { _ in self.networkRestoredCount += 1 }
        )
    }

    func makeContainer() throws -> AppContainer {
        containersBuilt += 1
        return try AppContainer(inMemory: true)
    }
}

private struct LaunchFailure: Error {}

@Suite("Shared launch")
struct AppLauncherTests {

    @Test("two scenes asking together get one container, built and prepared once")
    func concurrentCallersShareOneLaunch() async throws {
        let recorder = LaunchRecorder()
        let launcher = AppLauncher(makeContainer: recorder.makeContainer, steps: recorder.steps())

        async let first = launcher.container()
        async let second = launcher.container()
        let (a, b) = await (first, second)

        let container = try #require(a)
        #expect(b === container)
        #expect(recorder.containersBuilt == 1)

        await launcher.sessionRestored()
        await launcher.sessionRestored()
        #expect(recorder.events == ["prepare", "restore", "background"])
    }

    @Test("a caller arriving after the launch gets the same container without relaunching")
    func lateCallerReusesLaunch() async throws {
        let recorder = LaunchRecorder()
        let launcher = AppLauncher(makeContainer: recorder.makeContainer, steps: recorder.steps())

        let first = try #require(await launcher.container())
        await launcher.sessionRestored()
        let second = await launcher.container()

        #expect(second === first)
        #expect(recorder.containersBuilt == 1)
        #expect(recorder.events == ["prepare", "restore", "background"])
    }

    @Test("a container that cannot be built yields nil, runs no step, and is not retried")
    func failedContainerIsNotRetried() async {
        let recorder = LaunchRecorder()
        let launcher = AppLauncher(
            makeContainer: {
                recorder.containersBuilt += 1
                throw LaunchFailure()
            },
            steps: recorder.steps()
        )

        #expect(await launcher.container() == nil)
        #expect(await launcher.container() == nil)
        await launcher.sessionRestored()

        #expect(recorder.containersBuilt == 1)
        #expect(recorder.events.isEmpty)
        #expect(recorder.networkRestoredCount == 0)
    }

    @Test("reacts once at launch when online, then only when the network comes back")
    func reactsToConnectivityChanges() async throws {
        let recorder = LaunchRecorder()
        let launcher = AppLauncher(makeContainer: recorder.makeContainer, steps: recorder.steps())
        let container = try #require(await launcher.container())
        let state = container.serverState

        // ServerState starts optimistic (online), like the window's first `.task(id:)` run.
        await launcher.connectivityTask?.value
        #expect(recorder.networkRestoredCount == 1)

        state.isOnline = false
        await launcher.connectivityCheck?.value
        #expect(recorder.networkRestoredCount == 1)

        // NetworkMonitor rewrites the same value on every path update: that is not a change.
        state.isOnline = false
        await launcher.connectivityCheck?.value
        #expect(recorder.networkRestoredCount == 1)

        state.isOnline = true
        await launcher.connectivityCheck?.value
        await launcher.connectivityTask?.value
        #expect(recorder.networkRestoredCount == 2)

        // Same for a repeated online write: no second reaction to the same reconnection.
        state.isOnline = true
        await launcher.connectivityCheck?.value
        await launcher.connectivityTask?.value
        #expect(recorder.networkRestoredCount == 2)
    }
}
