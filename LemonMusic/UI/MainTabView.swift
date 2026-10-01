// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab: AppTab = .home
    @State private var showingPlayer = false

    private enum AppTab: Hashable { case home, discover, library, search }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs
                    .tabViewBottomAccessory {
                        if model.playback.currentTrack != nil {
                            TabBarMiniPlayer(showingPlayer: $showingPlayer)
                        }
                    }
            } else {
                tabs
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if model.playback.currentTrack != nil {
                            MiniPlayerView(showingPlayer: $showingPlayer, presentation: .legacy)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            FullPlayerView()
        }
        .overlay(alignment: .top) {
            if model.sessionState == .offline {
                Text("离线模式")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
        }
        .alert("无法播放", isPresented: Binding(
            get: { model.playback.lastError != nil },
            set: { if !$0 { model.playback.lastError = nil } }
        )) {
            Button("知道了", role: .cancel) { model.playback.lastError = nil }
        } message: {
            Text(model.playback.lastError ?? "请稍后重试")
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("首页", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("发现", systemImage: "sparkles", value: AppTab.discover) {
                NavigationStack { DiscoverView() }
            }
            Tab("音乐库", systemImage: "music.note.list", value: AppTab.library) {
                NavigationStack { LibraryView() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct TabBarMiniPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Binding var showingPlayer: Bool

    var body: some View {
        MiniPlayerView(
            showingPlayer: $showingPlayer,
            presentation: placement == .inline ? .inlineAccessory : .expandedAccessory
        )
    }
}
