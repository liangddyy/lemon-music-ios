import AppIntents
import SwiftUI
import WidgetKit

struct PlaybackEntry: TimelineEntry {
    let date: Date
    let snapshot: PlaybackWidgetSnapshot
    var artwork: UIImage?
}

struct PlaybackTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaybackEntry {
        PlaybackEntry(date: .now, snapshot: PlaybackWidgetSnapshot(
            isSignedIn: true, trackID: "preview", title: "晴天", artist: "周杰伦"
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaybackEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaybackEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(30 * 60))))
    }

    private func entry() -> PlaybackEntry {
        let store = PlaybackWidgetStore()
        let snapshot = store.read()
        return PlaybackEntry(date: .now, snapshot: snapshot, artwork: store.artwork(for: snapshot).flatMap(UIImage.init(data:)))
    }
}

struct PlaybackWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlaybackEntry
    private let orange = Color(red: 1, green: 0.43, blue: 0.08)
    private var snapshot: PlaybackWidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: snapshot.isPlaying ? "waveform" : "headphones")
                    .font(.title2)
                    .widgetAccentable()
            case .accessoryRectangular:
                HStack(spacing: 10) {
                    Image(systemName: snapshot.isPlaying ? "waveform" : "headphones")
                        .font(.title2).widgetAccentable()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.hasTrack ? snapshot.title : "柠檬音乐").font(.headline).lineLimit(1)
                        Text(snapshot.hasTrack ? snapshot.artist : emptySubtitle).font(.caption).lineLimit(1)
                    }
                    .privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .systemMedium:
                if snapshot.hasTrack { medium } else { empty }
            default:
                if snapshot.hasTrack { small } else { empty }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(PlaybackWidgetSnapshot.playerURL)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                artwork(size: 58)
                Spacer(minLength: 8)
                control(.toggle, size: 44)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(snapshot.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .privacySensitive()
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            artwork(size: 106)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "headphones").foregroundStyle(orange)
                    Text(snapshot.isPlaying ? "正在播放" : "继续聆听").foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.medium))
                Text(snapshot.title).font(.headline).lineLimit(1).privacySensitive()
                Text(snapshot.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    control(.previous, size: 44)
                    control(.toggle, size: 44)
                    control(.next, size: 44)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptySubtitle: String { snapshot.isSignedIn ? "打开音乐，开始聆听" : "打开音乐并登录" }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "headphones")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(orange)
                .widgetAccentable()
            Spacer(minLength: 0)
            Text("柠檬音乐").font(.headline)
            Text(emptySubtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func artwork(size: CGFloat) -> some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let image = entry.artwork {
                Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.35, weight: .medium)).foregroundStyle(orange)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .privacySensitive()
        .accessibilityHidden(true)
    }

    private func control(_ action: WidgetPlaybackAction, size: CGFloat) -> some View {
        let isToggle = action == .toggle
        let symbol = isToggle ? (snapshot.isPlaying ? "pause.fill" : "play.fill") : (action == .next ? "forward.fill" : "backward.fill")
        return Button(intent: PlaybackWidgetIntent(action: action)) {
            Image(systemName: symbol)
                .font(.system(size: isToggle ? 15 : 16, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(isToggle ? Color.white : Color.primary)
                .background(isToggle ? orange : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isToggle ? (snapshot.isPlaying ? "暂停" : "播放") : (action == .next ? "下一首" : "上一首"))
    }
}

@main
struct LemonMusicPlaybackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PlaybackWidgetSnapshot.kind, provider: PlaybackTimelineProvider()) { entry in
            PlaybackWidgetView(entry: entry)
        }
        .configurationDisplayName("随时聆听")
        .description("继续播放喜欢的音乐。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

#Preview(as: .systemSmall) {
    LemonMusicPlaybackWidget()
} timeline: {
    PlaybackEntry(date: .now, snapshot: PlaybackWidgetSnapshot(isSignedIn: true, trackID: "preview", title: "晴天", artist: "周杰伦"))
    PlaybackEntry(date: .now, snapshot: .signedOut)
}

#Preview(as: .systemMedium) {
    LemonMusicPlaybackWidget()
} timeline: {
    PlaybackEntry(date: .now, snapshot: PlaybackWidgetSnapshot(isSignedIn: true, trackID: "preview", title: "晴天", artist: "周杰伦", isPlaying: true))
}
