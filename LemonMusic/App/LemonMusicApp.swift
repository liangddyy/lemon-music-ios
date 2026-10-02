// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

@main
struct LemonMusicApp: App {
    @UIApplicationDelegateAdaptor(LemonAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        do {
            _model = State(initialValue: try AppModel(inMemory: ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures")))
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
                .modifier(UITestPresentation())
        }
    }
}

private struct UITestPresentation: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestingLargeType") {
            content.environment(\.dynamicTypeSize, .accessibility3)
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-uiTestingDark") ? .dark : nil)
        } else {
            content.preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-uiTestingDark") ? .dark : nil)
        }
        #else
        content
        #endif
    }
}
