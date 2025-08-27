import Foundation
import Combine
import Starscream

public final class SignalKClient: ObservableObject, WebSocketDelegate {
    // Generic store for arbitrary subscribed path -> value
    @Published public var pathValues: [String: CodableValue] = [:]

    private var socket: WebSocket?
    private var cancellables = Set<AnyCancellable>()
    private var connected = false
    @Published public private(set) var isConnected: Bool = false
    
    // Connection state information
    @Published public private(set) var connectedHost: String? = nil
    @Published public private(set) var connectedPort: Int? = nil
    @Published public private(set) var connectionURL: String? = nil

    public init() {}

    // Optional: automatic subscribe=all on by default for compatibility; apps can turn off
    public var subscribeAllOnConnect: Bool = true

    // Signal K context (default self vessel)
    public var context: String = "vessels.self"
    // Optional auth token (Bearer)
    public var authToken: String?
    // Optional TLS override; when nil we auto-detect by port
    public var useTLS: Bool?
    
    // API client for HTTP requests
    public lazy var apiClient: SignalKAPIClient = {
        let client = SignalKAPIClient()
        // Forward API client state changes to our published properties
        client.$hasValidToken
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasValidToken)
        client.$isTokenRequestPending
            .receive(on: DispatchQueue.main)
            .assign(to: &$isTokenRequestPending)
        return client
    }()
    
    // Expose API client state for easy app access
    @Published public private(set) var hasValidToken: Bool = false
    @Published public private(set) var isTokenRequestPending: Bool = false

    // Queue of subscriptions requested before or after connect
    private var pendingSubscriptions: [SignalKSubscriptionRequest] = []

    // Request the server to subscribe to custom Signal K paths
    public func subscribe(paths: [SignalKSubscriptionRequest]) {
        pendingSubscriptions.append(contentsOf: paths)
        sendPendingSubscriptionsIfConnected()
    }

    // Unsubscribe from paths
    public func unsubscribe(paths: [String]) {
        guard let socket = self.socket, connected, !paths.isEmpty else { return }
        let message: [String: Any] = [
            "context": context,
            "unsubscribe": paths.map { ["path": $0] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: message, options: []),
           let json = String(data: data, encoding: .utf8) {
            socket.write(string: json)
        }
    }

    public func connect(to host: String, port: Int) {
        // Store connection info
        connectedHost = host
        connectedPort = port
        
        // Optionally request server-side subscription to all updates
        let urlScheme: String
        if let useTLS = useTLS {
            urlScheme = useTLS ? "wss" : "ws"
        } else {
            urlScheme = (port == 443 || port == 3443) ? "wss" : "ws"
        }
        let urlString: String
        if subscribeAllOnConnect {
            urlString = "\(urlScheme)://\(host):\(port)/signalk/v1/stream?subscribe=all"
        } else {
            urlString = "\(urlScheme)://\(host):\(port)/signalk/v1/stream?subscribe=none"
        }
        
        // Store connection URL
        connectionURL = urlString
        
        let url = URL(string: urlString)!
        var request = URLRequest(url: url)
    // Some Signal K servers expect subprotocol negotiation
    request.setValue("signalk, ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        socket = WebSocket(request: request)
        socket?.delegate = self
        
        // Configure API client with the same base URL
        let scheme = request.url?.scheme ?? "http"
        let apiScheme = scheme == "wss" ? "https" : "http"
        if let apiURL = URL(string: "\(apiScheme)://\(host):\(port)") {
            apiClient.setBaseURL(apiURL)
        }
        
        socket?.connect()
    }

    public func disconnect() {
        socket?.disconnect()
        connectedHost = nil
        connectedPort = nil
        connectionURL = nil
    }

    public func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected(_):
            // Send any pending custom requests
            connected = true
            isConnected = true
            sendPendingSubscriptionsIfConnected()
        case .text(let text):
            parseDelta(jsonString: text)
        case .disconnected(_, _):
            connected = false
            isConnected = false
            connectedHost = nil
            connectedPort = nil
            connectionURL = nil
        case .cancelled:
            connected = false
            isConnected = false
            connectedHost = nil
            connectedPort = nil
            connectionURL = nil
        case .error(_):
            connected = false
            isConnected = false
            connectedHost = nil
            connectedPort = nil
            connectionURL = nil
        default:
            break
        }
    }

    private func sendPendingSubscriptionsIfConnected() {
        guard let socket = self.socket, connected, !pendingSubscriptions.isEmpty else { return }
        let subscribeMessage: [String: Any] = [
            "context": context,
            "subscribe": pendingSubscriptions.map { $0.toDictionary() }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: subscribeMessage, options: []),
           let json = String(data: data, encoding: .utf8) {
            socket.write(string: json)
            // Clear once sent to avoid duplicate re-sends on reconnect unless re-queued
            pendingSubscriptions.removeAll()
        }
    }

    private func parseDelta(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let delta = try? JSONDecoder().decode(SignalKDelta.self, from: data) else { return }

        let ctx = delta.context
        for update in delta.updates {
            for v in update.values {
                // Effective path: prefer value.path; else use update.path
                guard let rawPath = v.path ?? update.path else { continue }
                // Derive absolute and relative keys
                let absolutePath: String
                if let ctx = ctx, !rawPath.hasPrefix(ctx + ".") {
                    // If rawPath is relative, make absolute via context
                    absolutePath = ctx + "." + rawPath
                } else {
                    absolutePath = rawPath
                }
                let relativePath: String
                if let ctx = ctx, absolutePath.hasPrefix(ctx + ".") {
                    relativePath = String(absolutePath.dropFirst(ctx.count + 1))
                } else if absolutePath.hasPrefix("vessels.") {
                    // Fallback: strip any vessels.<id>. prefix
                    if let firstDot = absolutePath.dropFirst("vessels.".count).firstIndex(of: ".") {
                        relativePath = String(absolutePath[absolutePath.index(after: firstDot)...])
                    } else {
                        relativePath = absolutePath
                    }
                } else {
                    relativePath = absolutePath
                }
                DispatchQueue.main.async {
                    // Store both absolute and relative paths for flexible lookup
                    self.pathValues[absolutePath] = v.value
                    self.pathValues[relativePath] = v.value
                }
            }
        }
    }

}
