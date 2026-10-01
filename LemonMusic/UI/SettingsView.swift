// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("账户") {
                LabeledContent("服务器", value: model.profile?.baseURL ?? "")
                LabeledContent("用户", value: model.profile?.user?.displayName ?? model.profile?.username ?? "")
                Button("更换服务器", role: .destructive) { Task { await model.changeServer(); dismiss() } }
            }

            Section("音频缓存") {
                Picker("缓存上限", selection: Binding(
                    get: { model.audioCache.maxBytes },
                    set: { model.audioCache.maxBytes = $0; model.audioCache.enforceLimit(protectedKey: model.playback.currentTrack?.id) }
                )) {
                    ForEach(AudioCache.sizeOptions, id: \.self) { Text(formatBytes($0)).tag($0) }
                }
                LabeledContent("已使用", value: formatBytes(model.audioCache.usedBytes()))
                Button("清空音频缓存", role: .destructive) { model.clearAudioCache() }
            }

            Section("资料与封面") {
                Button("刷新音乐库") { Task { await model.refreshAll(force: true) } }
                Button("清空封面缓存", role: .destructive) { model.clearArtworkCache() }
            }

            Section("关于") {
                LabeledContent("应用", value: "柠檬音乐")
                LabeledContent("API", value: "Lemon Music v1")
                Text("本项目遵循 MPL-2.0 开源许可。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("退出登录", role: .destructive) { Task { await model.logout(); dismiss() } }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("完成") { dismiss() } }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
