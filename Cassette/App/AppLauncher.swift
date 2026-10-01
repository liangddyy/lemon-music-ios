// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import OSLog

/// Runs Cassette's launch sequence once per process, for whichever scene asks first.
///
/// The iPhone window and, from v2.0, the CarPlay scene both need a ready container, and either can
/// connect first: CarPlay can launch the app with no window at all, so the sequence cannot live in a
/// view's `.task`. Every caller awaits the same `Task`, so the container is built, wired and restored
/// exactly once. Two containers would mean two players on one audio session and every remote
/// command registered twice.
///
/// The test-and-set on `launchTask` has no suspension point between them and runs on the main actor,
/// so two scenes connecting together cannot both start a launch.
@MainActor
final class AppLauncher {
    private let makeContainer: () throws -> AppContainer
    private let steps: AppLaunchSteps

    private var launchTask: Task<AppContainer?, Never>?
    /// The saved session being restored. Exposed so a caller, or a test, can await it.
    private(set) var restoreTask: Task<Void, Never>?

    // Connectivity: mirrors what `.task(id: serverState.isOnline)` did on the window, minus the window.
    private var lastIsOnline: Bool?
    /// The reaction to the network coming back, cancelled when connectivity flips again —
    /// the same cancellation `.task(id:)` applied.
    private(set) var connectivityTask: Task<Void, Never>?
    /// The re-read scheduled by the last observed change, so a test can await it.
    private(set) var connectivityCheck: Task<Void, Never>?

    init(makeContainer: @escaping () throws -> AppContainer, steps: AppLaunchSteps) {
        self.makeContainer = makeContainer
        self.steps = steps
    }

    /// The container, once it is wired and ready for UI. The session restore carries on behind it,
    /// exactly as it did when the window's `.task` published the container before restoring.
    /// `nil` when the container cannot be built; that is not retried (issue #99).
    func container() async -> AppContainer? {
        if let launchTask { return await launchTask.value }
        let task = Task { await launch() }
        launchTask = task
        return await task.value
    }

    /// Returns once the saved session is restored, launching first if nobody has yet.
    func sessionRestored() async {
        _ = await container()
        await restoreTask?.value
    }

    private func launch() async -> AppContainer? {
        Logger.boot.notice("🟡 AppContainer init start")
        let container: AppContainer
        do {
            container = try makeContainer()
        } catch {
            Logger.boot.error("AppContainer init failed — launch stops here: \(error, privacy: .public)")
            return nil
        }
        await steps.prepare(container)
        trackConnectivity(of: container)
        restoreTask = Task {
            await steps.restore(container)
            steps.background(container)
        }
        return container
    }

    // MARK: - Connectivity

    private func trackConnectivity(of container: AppContainer) {
        let isOnline = withObservationTracking {
            container.serverState.isOnline
        } onChange: { [weak self] in
            // ServerState is main-actor bound, so this fires on the main actor, inside the write and
            // before the new value is stored. Read it on the next turn, after the write completes.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connectivityCheck = Task { self.trackConnectivity(of: container) }
            }
        }
        // NetworkMonitor writes on every path update; only a real change counts, as with `.task(id:)`.
        guard isOnline != lastIsOnline else { return }
        lastIsOnline = isOnline
        connectivityTask?.cancel()
        connectivityTask = nil
        guard isOnline else { return }
        connectivityTask = Task { await steps.networkRestored(container) }
    }
}

/// The work `AppLauncher` sequences. Injected so tests can record the order without a real launch.
struct AppLaunchSteps {
    /// Wiring and services that must be live before any UI reads the container.
    var prepare: @MainActor (AppContainer) async -> Void
    /// Server state and the saved session. Runs after the container is handed out.
    var restore: @MainActor (AppContainer) async -> Void
    /// Fire-and-forget housekeeping, started once the session is restored.
    var background: @MainActor (AppContainer) -> Void
    /// What to do each time the network comes back, and once at launch when already online.
    var networkRestored: @MainActor (AppContainer) async -> Void
}
