// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCacheClear = false
    @State private var usedCacheBytes: Int64 = 0
    @State private var cacheClearMessage: String?

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
                    set: {
                        model.audioCache.maxBytes = $0
                        model.audioCache.enforceLimit(protectedKey: model.playback.currentTrack?.id)
                        refreshCacheUsage()
                    }
                )) {
                    ForEach(AudioCache.sizeOptions, id: \.self) { Text(formatBytes($0)).tag($0) }
                }
                LabeledContent("已使用") {
                    Text(formatBytes(usedCacheBytes))
                        .accessibilityIdentifier("settings.audioCacheUsed")
                }
                Button("清空音频缓存", role: .destructive) { confirmingCacheClear = true }
                    .accessibilityIdentifier("settings.clearAudioCache")
                if let cacheClearMessage {
                    Label(cacheClearMessage, systemImage: usedCacheBytes == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(usedCacheBytes == 0 ? Color.green : Color.orange)
                        .accessibilityIdentifier("settings.cacheClearResult")
                }
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
        .onAppear { refreshCacheUsage() }
        .alert("清空音频缓存？", isPresented: $confirmingCacheClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                model.clearAudioCache()
                refreshCacheUsage()
                cacheClearMessage = usedCacheBytes == 0 ? "音频缓存已清空" : "部分缓存未能清理，请重试"
            }
        } message: {
            Text("仅清除本机音频缓存，并取消未完成的本机缓存任务。不会删除 NAS 上的歌曲，再次播放可能需要联网。")
        }
    }

    private func refreshCacheUsage() {
        usedCacheBytes = model.audioCache.usedBytes()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
