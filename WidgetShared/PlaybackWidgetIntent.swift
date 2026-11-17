import AppIntents
import Foundation

nonisolated enum WidgetPlaybackAction: String, AppEnum {
    case toggle, previous, next

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "播放操作"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .toggle: "播放或暂停", .previous: "上一首", .next: "下一首",
    ]
}

struct PlaybackWidgetIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "控制柠檬音乐播放"
    static let isDiscoverable = false

    @Parameter(title: "操作", default: .toggle)
    var action: WidgetPlaybackAction

    init() {}

    init(action: WidgetPlaybackAction) {
        self.action = action
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await execute()
        return .result()
    }

    @MainActor
    private func execute() async throws {
        #if !WIDGET_EXTENSION
        let model = AppRuntime.shared.model
        await model.bootstrap(includeDiscovery: false)
        guard model.sessionState == .ready || model.sessionState == .offline else {
            throw WidgetPlaybackError.signInRequired
        }
        guard model.playback.currentTrack != nil else { throw WidgetPlaybackError.noQueue }
        switch action {
        case .toggle: model.playback.togglePlayPause()
        case .previous: await model.playback.previous()
        case .next: await model.playback.next()
        }
        #else
        throw WidgetPlaybackError.openApp
        #endif
    }
}

nonisolated enum WidgetPlaybackError: LocalizedError {
    case signInRequired, noQueue, openApp

    var errorDescription: String? {
        switch self {
        case .signInRequired: "请先在柠檬音乐中登录"
        case .noQueue: "请先在柠檬音乐中选择歌曲"
        case .openApp: "请打开柠檬音乐后继续播放"
        }
    }
}
