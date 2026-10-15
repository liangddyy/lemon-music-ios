import Foundation

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let model: AppModel

    private init() {
        do {
            model = try AppModel(inMemory: ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures"))
        } catch {
            fatalError("无法初始化本地数据库：\(error)")
        }
    }
}
