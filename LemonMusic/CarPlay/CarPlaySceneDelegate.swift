import CarPlay

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let coordinator = CarPlayCoordinator(model: AppRuntime.shared.model)
        self.coordinator = coordinator
        interfaceController.delegate = coordinator
        coordinator.connect(to: CarPlayInterface(interfaceController))
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        interfaceController.delegate = nil
        coordinator?.disconnect()
        coordinator = nil
    }
}
