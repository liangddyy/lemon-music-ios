// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab: AppTab = .home
    @State private var showingPlayer = false

    private enum AppTab: Hashable { case home, discover, library, search }

    var body: some View {
        Group {
            if #available(iOS 26.1, *) {
                tabs
                    .tabViewBottomAccessory(isEnabled: model.playback.currentTrack != nil) {
                        TabBarMiniPlayer(showingPlayer: $showingPlayer)
                    }
            } else if #available(iOS 26.0, *) {
                tabs
                    .tabViewBottomAccessory {
                        if model.playback.currentTrack != nil {
                            TabBarMiniPlayer(showingPlayer: $showingPlayer)
                        }
                    }
            } else {
                tabs
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            FullPlayerView()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = model.userDataSyncError {
                HStack(spacing: 8) {
                    Label("数据同步失败", systemImage: "exclamationmark.circle")
                    Text(error).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("重试同步", systemImage: "arrow.clockwise") { Task { await model.retryUserDataSync() } }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .font(.caption)
                .padding(.horizontal)
                .background(Color(.secondarySystemBackground))
            }
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
            get: { !showingPlayer && model.playback.lastError != nil },
            set: { if !$0 && !showingPlayer { model.playback.lastError = nil } }
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
                    .modifier(LegacyMiniPlayerInset(showingPlayer: $showingPlayer))
            }
            Tab("发现", systemImage: "sparkles", value: AppTab.discover) {
                NavigationStack { DiscoverView() }
                    .modifier(LegacyMiniPlayerInset(showingPlayer: $showingPlayer))
            }
            Tab("音乐库", systemImage: "music.note.list", value: AppTab.library) {
                NavigationStack { LibraryView() }
                    .modifier(LegacyMiniPlayerInset(showingPlayer: $showingPlayer))
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
                    .modifier(LegacyMiniPlayerInset(showingPlayer: $showingPlayer))
            }
        }
    }
}

private struct LegacyMiniPlayerInset: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var showingPlayer: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            // Tab content's safe area ends above the tab bar; TabView's does not.
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if model.playback.currentTrack != nil {
                    MiniPlayerView(showingPlayer: $showingPlayer, presentation: .legacy)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
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
