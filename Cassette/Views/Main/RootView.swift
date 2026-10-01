// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct RootView: View {
    @Environment(\.appContainer) private var container
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        if let serverState = container?.serverState {
            if serverState.isLoadingPersistedState {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if serverState.activeServer != nil && onboardingComplete {
                #if os(macOS)
                RootViewMacOS()
                    .accentColor(.cassetteAccent)
                    .launchedScreen("root.main")
                #else
                MainTabView()
                    .accentColor(.cassetteAccent)
                    .launchedScreen("root.main")
                #endif
            } else {
                OnboardingView()
                    .launchedScreen("root.onboarding")
            }
        }
    }
}

private extension View {
    /// Marks the first real screen after launch, for the UI launch test. The identifier sits on a
    /// containing element so it does not overwrite the children's own accessibility.
    func launchedScreen(_ identifier: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}
