import CarPlay
import OSLog

@MainActor
protocol CarPlayPresenting: AnyObject {
    var templates: [CPTemplate] { get }
    var imageScale: CGFloat { get }
    func setRoot(_ template: CPTemplate)
    func push(_ template: CPTemplate)
    func pop(to template: CPTemplate)
    func present(_ alert: CPAlertTemplate)
    func dismissAlert()
}

@MainActor
final class CarPlayInterface: CarPlayPresenting {
    private let controller: CPInterfaceController
    private let logger = Logger(subsystem: "top.btop.music", category: "CarPlay")

    init(_ controller: CPInterfaceController) {
        self.controller = controller
    }

    var templates: [CPTemplate] { controller.templates }
    var imageScale: CGFloat { controller.carTraitCollection.displayScale }

    func setRoot(_ template: CPTemplate) {
        controller.setRootTemplate(template, animated: false, completion: completion)
    }

    func push(_ template: CPTemplate) {
        controller.pushTemplate(template, animated: true, completion: completion)
    }

    func pop(to template: CPTemplate) {
        controller.pop(to: template, animated: true, completion: completion)
    }

    func present(_ alert: CPAlertTemplate) {
        guard controller.presentedTemplate == nil else { return }
        controller.presentTemplate(alert, animated: true, completion: completion)
    }

    func dismissAlert() {
        controller.dismissTemplate(animated: true, completion: completion)
    }

    private func completion(_ success: Bool, _ error: Error?) {
        if !success { logger.error("CarPlay 模板操作失败：\(error?.localizedDescription ?? "未知错误", privacy: .public)") }
    }
}
