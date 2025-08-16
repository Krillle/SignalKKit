import Foundation
import Combine
import Starscream

public final class SignalKClient: ObservableObject, WebSocketDelegate {
    @Published public var courseOverGround: Double?
    @Published public var speedOverGround: Double?
    @Published public var latitude: Double?
    @Published public var longitude: Double?
    @Published public var waterTemperature: Double?
    @Published public var tankLevels: [String: Double] = [:]
    // Generic store for arbitrary subscribed path -> value (Double or String for now)
    @Published public var pathValues: [String: CodableValue] = [:]

    private var socket: WebSocket?
    private var cancellables = Set<AnyCancellable>()

    public init() {}

    // Optional: turn off automatic subscribe=all if apps want manual control
    public var subscribeAllOnConnect: Bool = true

    // Queue of subscriptions requested before or after connect
    private var pendingSubscriptions: [SignalKSubscriptionRequest] = []

    // Request the server to subscribe to custom Signal K paths
    public func subscribe(paths: [SignalKSubscriptionRequest]) {
        pendingSubscriptions.append(contentsOf: paths)
        sendPendingSubscriptionsIfConnected()
    }

    public func connect(to host: String, port: Int) {
        // Optionally request server-side subscription to all updates
        let urlString: String
        if subscribeAllOnConnect {
            urlString = "ws://\(host):\(port)/signalk/v1/stream?subscribe=all"
        } else {
            urlString = "ws://\(host):\(port)/signalk/v1/stream"
        }
        let url = URL(string: urlString)!
        var request = URLRequest(url: url)
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }

    public func disconnect() {
        socket?.disconnect()
    }

    public func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected(_):
            // Proactively subscribe to key paths and any pending custom requests
            var subscribe: [[String: Any]] = [
                ["path": "navigation.position", "policy": "instant"],
                ["path": "navigation.courseOverGroundTrue", "policy": "instant"],
                ["path": "navigation.speedOverGround", "policy": "instant"],
                ["path": "environment.water.temperature", "policy": "instant"]
            ]
            subscribe.append(contentsOf: pendingSubscriptions.map { $0.toDictionary() })
            let subscribeMessage: [String: Any] = [
                "context": "vessels.self",
                "subscribe": subscribe
            ]
            if let data = try? JSONSerialization.data(withJSONObject: subscribeMessage, options: []),
               let json = String(data: data, encoding: .utf8) {
                client.write(string: json)
            }
        case .text(let text):
            parseDelta(jsonString: text)
        default:
            break
        }
    }

    private func sendPendingSubscriptionsIfConnected() {
        guard case .connected = socket?.isConnected, let socket else { return }
        let subscribeMessage: [String: Any] = [
            "context": "vessels.self",
            "subscribe": pendingSubscriptions.map { $0.toDictionary() }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: subscribeMessage, options: []),
           let json = String(data: data, encoding: .utf8) {
            socket.write(string: json)
        }
    }

    private func parseDelta(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let delta = try? JSONDecoder().decode(SignalKDelta.self, from: data) else { return }

        for update in delta.updates {
            for value in update.values {
                switch value.path {
                case "navigation.courseOverGroundTrue":
                    updatePublished(\.courseOverGround, with: value.value.doubleValue())
                case "navigation.speedOverGround":
                    updatePublished(\.speedOverGround, with: value.value.doubleValue())
                case "environment.water.temperature":
                    updatePublished(\.waterTemperature, with: value.value.doubleValue())
                case let path where path.hasPrefix("tanks."):
                    if let tankLevel = value.value.doubleValue() {
                        DispatchQueue.main.async {
                            self.tankLevels[path] = tankLevel
                        }
                    }
                case "navigation.position":
                    if case .dict(let coords) = value.value {
                        DispatchQueue.main.async {
                            self.latitude = coords["latitude"]
                            self.longitude = coords["longitude"]
                        }
                    }
                case "navigation.position.latitude":
                    updatePublished(\.latitude, with: value.value.doubleValue())
                case "navigation.position.longitude":
                    updatePublished(\.longitude, with: value.value.doubleValue())
                default:
                    // Store generic values for paths apps explicitly subscribe to
                    DispatchQueue.main.async {
                        self.pathValues[value.path] = value.value
                    }
                }
            }
        }
    }

    private func updatePublished(_ keyPath: ReferenceWritableKeyPath<SignalKClient, Double?>, with newValue: Double?) {
        guard let newValue = newValue else { return }
        DispatchQueue.main.async { [weak self] in
            self?[keyPath: keyPath] = newValue
        }
    }
}
