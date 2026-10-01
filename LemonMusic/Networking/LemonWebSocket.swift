// Derived from Cassette, licensed under MPL-2.0.

import Foundation

@MainActor
final class LemonWebSocket {
    var onEvent: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var targetURL: URL?
    private var reconnectAttempt = 0
    private var stopped = true

    func connect(to url: URL) {
        stop()
        stopped = false
        targetURL = url
        open()
    }

    func stop() {
        stopped = true
        receiveTask?.cancel()
        reconnectTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        receiveTask = nil
        reconnectTask = nil
        task = nil
    }

    private func open() {
        guard !stopped, let targetURL else { return }
        let socket = URLSession.shared.webSocketTask(with: targetURL)
        task = socket
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                reconnectAttempt = 0
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
                      let type = root["type"]?.string else { continue }
                onEvent?(type)
            }
        } catch {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt)), 30)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }
}
