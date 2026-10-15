import CarPlay
import UIKit

final class LemonAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            configuration.sceneClass = CPTemplateApplicationScene.self
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }
        // SwiftUI wraps the returned delegate; returning its existing configuration wraps it twice.
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundCacheEvents.completionHandlers[identifier] = completionHandler
    }
}
