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

            Section {
                Toggle("省流模式", isOn: Binding(
                    get: { model.audioPolicy.dataSaverEnabled },
                    set: { model.audioPolicy.dataSaverEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.dataSaver")
            } header: {
                Text("网络与音质")
            } footer: {
                Text("默认开启。蜂窝网络下，在线音源的播放和新缓存请求使用 128K；关闭后及 Wi-Fi 下遵循服务器播放音质设置。已有本机缓存直接复用，NAS 本地歌曲仍按原码率传输。正在播放的歌曲不会中断，下一次在线加载生效。")
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
