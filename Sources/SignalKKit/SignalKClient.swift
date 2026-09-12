import Foundation
import Combine
import Starscream

protocol SignalKWebSocket: WebSocketClient {
    var delegate: WebSocketDelegate? { get set }
}

extension WebSocket: SignalKWebSocket {}

public final class SignalKClient: ObservableObject, WebSocketDelegate {
    // Generic store for arbitrary subscribed path -> value
    @Published public var pathValues: [String: CodableValue] = [:]
    @Published public var pathTimestamps: [String: Date] = [:]

    private var socket: SignalKWebSocket?
    private let socketFactory: (URLRequest) -> SignalKWebSocket
    private var cancellables = Set<AnyCancellable>()
    private var connected = false
    @Published public private(set) var isConnected: Bool = false
    
    // Connection state information
    @Published public private(set) var connectedHost: String? = nil
    @Published public private(set) var connectedPort: Int? = nil
    @Published public private(set) var connectionURL: String? = nil
    /// Most recent low-level WebSocket failure reported by Starscream.
    /// Consumers can surface this in their own diagnostics without coupling
    /// SignalKKit to a particular logging framework.
    @Published public private(set) var lastConnectionDiagnostic: String? = nil

    public convenience init() {
        self.init(socketFactory: { WebSocket(request: $0) })
    }

    init(socketFactory: @escaping (URLRequest) -> SignalKWebSocket) {
        self.socketFactory = socketFactory
    }

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
        // Forward API client state changes to our published properties.
        client.$hasValidToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.hasValidToken = value
            }
            .store(in: &cancellables)
        client.$isTokenRequestPending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTokenRequestPending = value
            }
            .store(in: &cancellables)
        return client
    }()
    
    // Expose API client state for easy app access
    @Published public private(set) var hasValidToken: Bool = false
    @Published public private(set) var isTokenRequestPending: Bool = false

    // Desired subscriptions belong to the client, not to one socket. Keep them
    // across reconnects and replay the complete set whenever a new socket opens.
    private var desiredSubscriptions: [SignalKSubscriptionRequest] = []
    private var pendingRequests: [String: CheckedContinuation<SignalKRequestResponse, Error>] = [:]
    // Request the server to subscribe to custom Signal K paths
    public func subscribe(paths: [SignalKSubscriptionRequest]) {
        guard !paths.isEmpty else { return }

        for request in paths {
            if let index = desiredSubscriptions.firstIndex(where: { $0.path == request.path }) {
                desiredSubscriptions[index] = request
            } else {
                desiredSubscriptions.append(request)
            }
        }

        sendSubscriptions(paths, ifConnectedTo: socket)
    }

    // Unsubscribe from paths
    public func unsubscribe(paths: [String]) {
        guard !paths.isEmpty else { return }
        let removedPaths = Set(paths)
        desiredSubscriptions.removeAll { removedPaths.contains($0.path) }

        guard let socket = self.socket, connected else { return }
        let message: [String: Any] = [
            "context": context,
            "unsubscribe": paths.map { ["path": $0] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: message, options: []),
           let json = String(data: data, encoding: .utf8) {
            socket.write(string: json)
        }
    }

    /// Send a Signal K PUT request over the active WebSocket stream.
    public func put(path: String, value: Any, units: String? = nil, source: String? = nil, timeout: TimeInterval = 8.0) async throws {
        guard let socket = self.socket, connected else {
            throw SignalKWebSocketRequestError.notConnected
        }

        let requestId = UUID().uuidString
        var put: [String: Any] = [
            "path": path,
            "value": value
        ]
        if let source {
            put["source"] = source
        }
        if let units {
            put["units"] = units
        }

        var message: [String: Any] = [
            "requestId": requestId,
            "put": put
        ]
        if let token = authToken ?? apiClient.currentAccessToken, !token.isEmpty {
            message["token"] = token
        }

        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: []),
              let json = String(data: data, encoding: .utf8) else {
            throw SignalKWebSocketRequestError.encodingFailed
        }

        let response = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            socket.write(string: json)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let continuation = self?.pendingRequests.removeValue(forKey: requestId) else { return }
                continuation.resume(throwing: SignalKWebSocketRequestError.timedOut)
            }
        }

        guard response.isSuccessful else {
            throw SignalKWebSocketRequestError.failed(
                statusCode: response.statusCode,
                state: response.state,
                message: response.message
            )
        }
    }

    public func connect(to host: String, port: Int) {
        if socket != nil {
            disconnect()
        }
        lastConnectionDiagnostic = nil
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

        let encodedHost = Self.urlEncodedHost(from: host)
        let subscribeValue = subscribeAllOnConnect ? "all" : "none"
        let urlString = "\(urlScheme)://\(encodedHost):\(port)/signalk/v1/stream?subscribe=\(subscribeValue)"
        guard let url = URL(string: urlString) else {
            connectionURL = nil
            return
        }

        // Store connection URL
        connectionURL = url.absoluteString

        let apiScheme = urlScheme == "wss" ? "https" : "http"
        if let apiURL = URL(string: "\(apiScheme)://\(encodedHost):\(port)") {
            apiClient.setBaseURL(apiURL)
        }
        
        var request = URLRequest(url: url)
        // Some Signal K servers expect subprotocol negotiation
        request.setValue("signalk, ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let token = authToken ?? apiClient.currentAccessToken
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let newSocket = socketFactory(request)
        socket = newSocket
        newSocket.delegate = self
        newSocket.connect()
    }

    private static func urlEncodedHost(from host: String) -> String {
        let decodedHost = canonicalBonjourHost(decodeBonjourEscapes(in: host))
        return decodedHost.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
    }

    private static func canonicalBonjourHost(_ host: String) -> String {
        guard host.hasSuffix(".local") else { return host }
        let localSuffix = ".local"
        let name = String(host.dropLast(localSuffix.count))
        guard let suffixStart = name.lastIndex(of: "("),
              name.hasSuffix(")"),
              suffixStart > name.startIndex,
              name[name.index(before: suffixStart)] == " " else {
            return host
        }

        let numberStart = name.index(after: suffixStart)
        let numberEnd = name.index(before: name.endIndex)
        guard numberStart < numberEnd,
              name[numberStart..<numberEnd].allSatisfy(\.isNumber) else {
            return host
        }

        return "\(name[..<name.index(before: suffixStart)])\(localSuffix)"
    }

    private static func decodeBonjourEscapes(in host: String) -> String {
        var decoded = ""
        var index = host.startIndex

        while index < host.endIndex {
            let character = host[index]
            if character == "\\" {
                let firstDigitIndex = host.index(after: index)
                let secondDigitIndex = firstDigitIndex < host.endIndex ? host.index(after: firstDigitIndex) : host.endIndex
                let thirdDigitIndex = secondDigitIndex < host.endIndex ? host.index(after: secondDigitIndex) : host.endIndex

                if thirdDigitIndex < host.endIndex {
                    let escapeEndIndex = host.index(after: thirdDigitIndex)
                    let escape = host[firstDigitIndex..<escapeEndIndex]
                    if escape.allSatisfy(\.isNumber),
                       let value = UInt8(escape) {
                        decoded.unicodeScalars.append(UnicodeScalar(value))
                        index = escapeEndIndex
                        continue
                    }
                }
            }

            decoded.append(character)
            index = host.index(after: index)
        }

        return decoded
    }

    public func disconnect() {
        let closingSocket = socket
        socket = nil
        closingSocket?.delegate = nil
        connected = false
        if isConnected {
            isConnected = false
        }
        connectedHost = nil
        connectedPort = nil
        connectionURL = nil
        failPendingRequests(with: SignalKWebSocketRequestError.notConnected)
        closingSocket?.disconnect(closeCode: 1000)
    }

    public func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        guard let socket,
              ObjectIdentifier(socket) == ObjectIdentifier(client) else {
            return
        }

        switch event {
        case .connected(_):
            // Replay the client's desired subscriptions for this socket.
            connected = true
            isConnected = true
            sendSubscriptions(desiredSubscriptions, ifConnectedTo: socket)
        case .text(let text):
            if !handleRequestResponse(jsonString: text) {
                parseDelta(jsonString: text)
            }
        case .disconnected(let reason, let code):
            lastConnectionDiagnostic = Self.disconnectionDiagnostic(
                reason: reason,
                code: code
            )
            connected = false
            isConnected = false
            connectedHost = nil
            connectedPort = nil
            connectionURL = nil
            failPendingRequests(with: SignalKWebSocketRequestError.notConnected)
        case .cancelled:
            connected = false
            isConnected = false
            connectedHost = nil
            connectedPort = nil
            connectionURL = nil
            failPendingRequests(with: SignalKWebSocketRequestError.notConnected)
        case .error(let error):
            lastConnectionDiagnostic = Self.errorDiagnostic(error)
            if authToken == nil, Self.isUnauthorizedHTTPUpgrade(error) {
                Task { [weak self] in
                    await self?.apiClient.recoverAccessAfterUnauthorizedResponse()
                }
            }
            connected = false
            isConnected = false
            connectedHost = nil
            connectedPort = nil
            connectionURL = nil
            failPendingRequests(with: SignalKWebSocketRequestError.notConnected)
        default:
            break
        }
    }

    private static func disconnectionDiagnostic(
        reason: String,
        code: UInt16
    ) -> String {
        let reason = reason.isEmpty ? "none" : reason
        return "WebSocket disconnected code=\(code) reason=\(reason)"
    }

    private static func errorDiagnostic(_ error: Error?) -> String {
        guard let error else {
            return "WebSocket error domain=unknown code=unknown description=none"
        }
        if let upgradeError = error as? HTTPUpgradeError {
            switch upgradeError {
            case .notAnUpgrade(let statusCode, let headers):
                let responseHeaders = [
                    "connection",
                    "content-type",
                    "location",
                    "sec-websocket-protocol",
                    "server",
                    "upgrade"
                ]
                .compactMap { name -> String? in
                    guard let value = headers[name] else { return nil }
                    return "\(name)=\(value)"
                }
                .joined(separator: ",")
                let headerDescription = responseHeaders.isEmpty ? "none" : responseHeaders
                return "WebSocket HTTP upgrade rejected status=\(statusCode) headers=\(headerDescription)"
            case .invalidData:
                return "WebSocket HTTP upgrade returned invalid data"
            }
        }
        if let webSocketError = error as? WSError {
            return "WebSocket error type=\(webSocketError.type) code=\(webSocketError.code) description=\(webSocketError.message)"
        }
        let nsError = error as NSError
        return "WebSocket error domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
    }

    private static func isUnauthorizedHTTPUpgrade(_ error: Error?) -> Bool {
        guard let upgradeError = error as? HTTPUpgradeError else { return false }
        guard case .notAnUpgrade(let statusCode, _) = upgradeError else { return false }
        return statusCode == 401
    }

    private func sendSubscriptions(
        _ subscriptions: [SignalKSubscriptionRequest],
        ifConnectedTo socket: SignalKWebSocket?
    ) {
        guard let socket, connected, !subscriptions.isEmpty else { return }
        let subscribeMessage: [String: Any] = [
            "context": context,
            "subscribe": subscriptions.map { $0.toDictionary() }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: subscribeMessage, options: []),
           let json = String(data: data, encoding: .utf8) {
            socket.write(string: json)
        }
    }

    private func parseDelta(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let delta = try? JSONDecoder().decode(SignalKDelta.self, from: data) else { return }

        let ctx = delta.context
        var timestampUpdates: [String: Date] = [:]
        var valueUpdates: [String: CodableValue] = [:]
        for update in delta.updates {
            let timestamp = SignalKTimestampParser.date(from: update.timestamp) ?? Date()
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
                timestampUpdates[absolutePath] = timestamp
                timestampUpdates[relativePath] = timestamp
                valueUpdates[absolutePath] = v.value
                valueUpdates[relativePath] = v.value
            }
        }

        guard !valueUpdates.isEmpty else { return }
        DispatchQueue.main.async {
            // Publish a complete delta at once. Timestamps still arrive before
            // values so pathValues observers can reject stale data immediately.
            self.pathTimestamps.merge(timestampUpdates) { _, new in new }
            self.pathValues.merge(valueUpdates) { _, new in new }
        }
    }
    
    private func handleRequestResponse(jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8),
              let response = try? JSONDecoder().decode(SignalKRequestResponse.self, from: data),
              pendingRequests[response.requestId] != nil else {
            return false
        }

        guard !response.isAcceptedPending else {
            guard let continuation = pendingRequests.removeValue(forKey: response.requestId) else {
                return true
            }
            continuation.resume(returning: response)
            return true
        }

        guard response.state != "PENDING" else {
            return true
        }

        guard let continuation = pendingRequests.removeValue(forKey: response.requestId) else {
            return true
        }
        continuation.resume(returning: response)
        return true
    }

    private func failPendingRequests(with error: Error) {
        let requests = pendingRequests
        pendingRequests.removeAll()
        requests.values.forEach { $0.resume(throwing: error) }
    }

}
