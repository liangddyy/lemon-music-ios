// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

@main
struct LemonMusicApp: App {
    @State private var model: AppModel

    init() {
        do {
            _model = State(initialValue: try AppModel())
        } catch {
            fatalError("无法初始化本地数据库：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color(red: 1.0, green: 0.43, blue: 0.08))
                .task { await model.bootstrap() }
        }
    }
}
