import Foundation

public class SignalKAPIClient: ObservableObject {
    
    // MARK: - Published Properties
    @Published public private(set) var isTokenRequestPending: Bool = false
    @Published public private(set) var hasValidToken: Bool = false
    
    // MARK: - Private Properties
    private let ubiquitousStore = NSUbiquitousKeyValueStore.default
    private var baseURL: URL?
    private var session: URLSession
    
    // Storage keys
    private let clientIdKey = "SignalKKit.clientId"
    private let tokenKey = "SignalKKit.accessToken"
    private let pendingHrefKey = "SignalKKit.pendingHref"
    private let tokenExpirationKey = "SignalKKit.tokenExpiration"
    private let deniedStateKey = "SignalKKit.deniedState"
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        self.session = URLSession(configuration: config)
        
        // Initialize hasValidToken based on stored token
        self.hasValidToken = currentToken != nil && !isTokenExpired
    }
    
    // MARK: - Public API
    
    /// Set the base URL for the Signal K server (scheme://host:port)
    public func setBaseURL(_ url: URL) {
        self.baseURL = url
        // Check token status when connecting to a server
        Task { await checkTokenStatus() }
    }
    
    /// Request access token on demand
    public func requestAccessToken(description: String? = nil) async throws {
        guard !isDenied else {
            throw SignalKError.accessDenied
        }
        
        await ensureTokenAvailable(description: description)
    }
    
    /// Perform GET request to Signal K API
    public func get(path: String) async throws -> Data {
        guard let baseURL = baseURL else {
            throw SignalKError.noServerURL
        }
        
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Use token if available
        if let token = currentToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SignalKError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw SignalKError.httpError(httpResponse.statusCode)
        }
        
        return data
    }
    
    /// Perform PUT request to Signal K API (automatically handles token acquisition)
    public func put(path: String, data: Data) async throws {
        // Ensure we have a token before attempting PUT
        await ensureTokenAvailable()
        
        guard let token = currentToken else {
            throw SignalKError.noAccessToken
        }
        
        guard let baseURL = baseURL else {
            throw SignalKError.noServerURL
        }
        
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SignalKError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SignalKError.httpError(httpResponse.statusCode)
        }
    }
    
    // MARK: - Token Management
    
    private var clientId: String {
        if let existing = ubiquitousStore.string(forKey: clientIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        ubiquitousStore.set(newId, forKey: clientIdKey)
        return newId
    }
    
    private var currentToken: String? {
        guard !isTokenExpired else {
            // Clear expired token
            ubiquitousStore.removeObject(forKey: tokenKey)
            ubiquitousStore.removeObject(forKey: tokenExpirationKey)
            return nil
        }
        return ubiquitousStore.string(forKey: tokenKey)
    }
    
    private var isTokenExpired: Bool {
        guard let expirationString = ubiquitousStore.string(forKey: tokenExpirationKey) else {
            return false // No expiration means token doesn't expire
        }
        
        let formatter = ISO8601DateFormatter()
        guard let expirationDate = formatter.date(from: expirationString) else {
            return false
        }
        
        return Date() >= expirationDate
    }
    
    private var pendingHref: String? {
        return ubiquitousStore.string(forKey: pendingHrefKey)
    }
    
    private var isDenied: Bool {
        return ubiquitousStore.bool(forKey: deniedStateKey)
    }
    
    private func clearDeniedState() {
        ubiquitousStore.removeObject(forKey: deniedStateKey)
    }
    
    private func setDeniedState() {
        ubiquitousStore.set(true, forKey: deniedStateKey)
    }
    
    private var appDisplayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return displayName
        }
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return bundleName
        }
        return "Signal K Kit App"
    }
    
    @MainActor
    private func ensureTokenAvailable(description: String? = nil) async {
        // Update published properties on main actor
        defer {
            hasValidToken = currentToken != nil
        }
        
        if currentToken != nil {
            return // Already have valid token
        }
        
        if isDenied {
            return // Access was denied, don't retry
        }
        
        // Check if we have a pending request
        if let href = pendingHref {
            await checkPendingRequest(href: href)
            if currentToken != nil {
                return
            }
        }
        
        // Request new token
        await requestNewAccessToken(description: description)
    }
    
    private func checkTokenStatus() async {
        await MainActor.run {
            hasValidToken = currentToken != nil
        }
        
        if let href = pendingHref {
            await checkPendingRequest(href: href)
        }
    }
    
    private func requestNewAccessToken(description: String?) async {
        guard let baseURL = baseURL else { return }
        
        await MainActor.run {
            isTokenRequestPending = true
        }
        
        defer {
            Task { @MainActor in
                isTokenRequestPending = false
            }
        }
        
        do {
            let url = baseURL.appendingPathComponent("/signalk/v1/access/requests")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let accessRequest = SignalKAccessRequest(
                clientId: clientId,
                description: description ?? appDisplayName
            )
            
            request.httpBody = try JSONEncoder().encode(accessRequest)
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else { return }
            
            if httpResponse.statusCode == 501 {
                // Server doesn't support access requests
                return
            }
            
            let accessResponse = try JSONDecoder().decode(SignalKAccessResponse.self, from: data)
            
            if httpResponse.statusCode == 202 || httpResponse.statusCode == 400 {
                // Store href for status checking
                if let href = accessResponse.href {
                    ubiquitousStore.set(href, forKey: pendingHrefKey)
                    // Check status immediately for 400 responses (existing request)
                    if httpResponse.statusCode == 400 {
                        await checkPendingRequest(href: href)
                    }
                }
            }
            
        } catch {
            // Handle error silently - token requests are optional
        }
    }
    
    private func checkPendingRequest(href: String) async {
        guard let baseURL = baseURL else { return }
        
        do {
            let url = baseURL.appendingPathComponent(href)
            let request = URLRequest(url: url)
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }
            
            let status = try JSONDecoder().decode(SignalKAccessStatus.self, from: data)
            
            if status.state == "COMPLETED" {
                // Clear pending request
                ubiquitousStore.removeObject(forKey: pendingHrefKey)
                
                if let accessRequest = status.accessRequest {
                    if accessRequest.permission == "APPROVED" {
                        // Store token
                        if let token = accessRequest.token {
                            ubiquitousStore.set(token, forKey: tokenKey)
                            
                            // Store expiration if provided
                            if let expirationTime = accessRequest.expirationTime {
                                ubiquitousStore.set(expirationTime, forKey: tokenExpirationKey)
                            }
                            
                            clearDeniedState()
                            
                            await MainActor.run {
                                hasValidToken = true
                            }
                        }
                    } else if accessRequest.permission == "DENIED" {
                        // Mark as denied to prevent further requests
                        setDeniedState()
                    }
                }
            }
            // If still PENDING, leave href in place for next check
            
        } catch {
            // Handle error silently
        }
    }
}

// MARK: - Error Types

public enum SignalKError: Error, LocalizedError {
    case noServerURL
    case noAccessToken
    case accessDenied
    case invalidResponse
    case httpError(Int)
    
    public var errorDescription: String? {
        switch self {
        case .noServerURL:
            return "No Signal K server URL configured"
        case .noAccessToken:
            return "No access token available"
        case .accessDenied:
            return "Access was denied by the server"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}
