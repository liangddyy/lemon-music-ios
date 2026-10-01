// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var scope: Scope = .local
    @State private var searchTask: Task<Void, Never>?

    private enum Scope: String, CaseIterable, Identifiable { case local = "音乐库", online = "在线"; var id: Self { self } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("范围", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if scope == .online { sourcePicker }

            results
        }
        .navigationTitle("搜索")
        .searchable(text: $query, prompt: scope == .local ? "搜索本地歌曲、歌手或专辑" : "搜索在线音乐")
        .onChange(of: query) { _, value in scheduleSearch(value) }
        .onChange(of: scope) { _, _ in scheduleSearch(query) }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sources) { source in
                    Button(source.name) {
                        Task { await model.selectSource(source.id); await model.searchOnline(query) }
                    }
                    .buttonStyle(.bordered)
                    .tint(model.selectedSourceID == source.id ? .orange : .secondary)
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var results: some View {
        let tracks = scope == .local ? model.localSearch(query) : model.onlineSearchResults
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyContentView(title: "搜索音乐", systemImage: "magnifyingglass", message: "输入歌曲、歌手或专辑名称")
        } else if model.isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            EmptyContentView(title: "没有找到结果", systemImage: "music.note", message: "换个关键词或音源试试")
        } else {
            List(tracks) { TrackRow(track: $0, queue: tracks) }
                .listStyle(.plain)
        }
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        guard scope == .online else { return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.searchOnline(value)
        }
    }
}
