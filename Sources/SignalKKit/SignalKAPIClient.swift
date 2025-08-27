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
    
    // Storage helper that falls back to UserDefaults if iCloud is not available
    private func getValue(forKey key: String) -> String? {
        // Try iCloud first
        let ubiquitousValue = ubiquitousStore.string(forKey: key)
        if ubiquitousValue != nil {
            return ubiquitousValue
        }
        // Fallback to UserDefaults
        return UserDefaults.standard.string(forKey: key)
    }
    
    private func setValue(_ value: String?, forKey key: String) {
        // Store in both locations
        if let value = value {
            ubiquitousStore.set(value, forKey: key)
            UserDefaults.standard.set(value, forKey: key)
            #if DEBUG
            print("[SignalKAPIClient] setValue: storing \(key) = \(value)")
            #endif
        } else {
            ubiquitousStore.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            #if DEBUG
            print("[SignalKAPIClient] setValue: removing \(key)")
            #endif
        }
    }
    
    private func getBoolValue(forKey key: String) -> Bool {
        // Try iCloud first
        if ubiquitousStore.object(forKey: key) != nil {
            return ubiquitousStore.bool(forKey: key)
        }
        // Fallback to UserDefaults
        return UserDefaults.standard.bool(forKey: key)
    }
    
    private func setBoolValue(_ value: Bool, forKey key: String) {
        ubiquitousStore.set(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }
    
    private func removeValue(forKey key: String) {
        ubiquitousStore.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        #if DEBUG
        print("[SignalKAPIClient] removeValue: removing \(key)")
        #endif
    }
    
    public init() {
        self.session = URLSession.shared
        
        // Initialize hasValidToken based on stored token
        self.hasValidToken = currentToken != nil && !isTokenExpired
    }
    
    // MARK: - Public API
    
    /// Set the base URL for the Signal K server (scheme://host:port)
    public func setBaseURL(_ url: URL) {
    self.baseURL = url
#if DEBUG
    print("[SignalKAPIClient] setBaseURL: \(url)")
#endif
    // Check token status when connecting to a server
    Task { await checkTokenStatus() }
    }
    
    /// Request access token on demand
    public func requestAccessToken(description: String? = nil) async throws {
        #if DEBUG
        print("[SignalKAPIClient] requestAccessToken called, isDenied=\(isDenied)")
        #endif
        guard !isDenied else {
            #if DEBUG
            print("[SignalKAPIClient] Access denied, not requesting token")
            #endif
            throw SignalKError.accessDenied
        }
        await ensureTokenAvailable(description: description)
    }
    
    /// Perform GET request to Signal K API
    public func get(path: String) async throws -> Data {
        guard let baseURL = baseURL else {
            #if DEBUG
            print("[SignalKAPIClient] GET failed: no baseURL")
            #endif
            throw SignalKError.noServerURL
        }
        
        return try await performGetRequest(path: path, retryOnAuth: true)
    }
    
    private func performGetRequest(path: String, retryOnAuth: Bool) async throws -> Data {
        guard let baseURL = baseURL else {
            throw SignalKError.noServerURL
        }
        
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        #if DEBUG
        print("[SignalKAPIClient] GET \(url)")
        #endif
        // Use token if available
        if let token = currentToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            #if DEBUG
            print("[SignalKAPIClient] GET using token")
            #endif
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            #if DEBUG
            print("[SignalKAPIClient] GET invalid response")
            #endif
            throw SignalKError.invalidResponse
        }
        #if DEBUG
        print("[SignalKAPIClient] GET status: \(httpResponse.statusCode)")
        #endif
        
        if httpResponse.statusCode == 401 && retryOnAuth {
            #if DEBUG
            print("[SignalKAPIClient] GET: 401 response, attempting to get/refresh token")
            #endif
            
            // Clear any existing invalid token
            if currentToken != nil {
                #if DEBUG
                print("[SignalKAPIClient] GET: clearing invalid token")
                #endif
                removeValue(forKey: tokenKey)
                removeValue(forKey: tokenExpirationKey)
                clearDeniedState()
                await MainActor.run {
                    hasValidToken = false
                }
            }
            
            // Try to get a token
            await ensureTokenAvailable()
            
            // Retry the request once with the new token (if we got one)
            if currentToken != nil {
                #if DEBUG
                print("[SignalKAPIClient] GET: retrying with new token")
                #endif
                return try await performGetRequest(path: path, retryOnAuth: false)
            }
            
            #if DEBUG
            print("[SignalKAPIClient] GET: no token available after retry")
            #endif
        }
        
        guard httpResponse.statusCode == 200 else {
            #if DEBUG
            print("[SignalKAPIClient] GET error: \(httpResponse.statusCode)")
            #endif
            throw SignalKError.httpError(httpResponse.statusCode)
        }
        
        return data
    }
    
    /// Perform PUT request to Signal K API (automatically handles token acquisition)
    public func put(path: String, data: Data) async throws {
        #if DEBUG
        print("[SignalKAPIClient] PUT \(path): ensureTokenAvailable...")
        #endif
        await ensureTokenAvailable()
        guard let token = currentToken else {
            #if DEBUG
            print("[SignalKAPIClient] PUT: no access token available after ensureTokenAvailable")
            #endif
            throw SignalKError.noAccessToken
        }
        guard let baseURL = baseURL else {
            #if DEBUG
            print("[SignalKAPIClient] PUT: no baseURL")
            #endif
            throw SignalKError.noServerURL
        }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        #if DEBUG
        print("[SignalKAPIClient] PUT sending to \(url)")
        #endif
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            #if DEBUG
            print("[SignalKAPIClient] PUT invalid response")
            #endif
            throw SignalKError.invalidResponse
        }
        #if DEBUG
        print("[SignalKAPIClient] PUT status: \(httpResponse.statusCode)")
        #endif
        guard (200...299).contains(httpResponse.statusCode) else {
            #if DEBUG
            print("[SignalKAPIClient] PUT error: \(httpResponse.statusCode)")
            #endif
            
            // If we get 401 with a token, the token was revoked on server - clear it and request new one
            if httpResponse.statusCode == 401 && currentToken != nil {
                #if DEBUG
                print("[SignalKAPIClient] PUT: 401 with token, clearing token and requesting new one")
                #endif
                removeValue(forKey: tokenKey)
                removeValue(forKey: tokenExpirationKey)
                clearDeniedState() // Allow new token requests
                await MainActor.run {
                    hasValidToken = false
                }
                // Try to get a new token for next time
                await ensureTokenAvailable()
            }
            
            throw SignalKError.httpError(httpResponse.statusCode)
        }
    }
    
    // MARK: - Token Management
    
    private var clientId: String {
        if let existing = getValue(forKey: clientIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        setValue(newId, forKey: clientIdKey)
        return newId
    }

    private var currentToken: String? {
        guard !isTokenExpired else {
            // Clear expired token
            removeValue(forKey: tokenKey)
            removeValue(forKey: tokenExpirationKey)
            return nil
        }
        return getValue(forKey: tokenKey)
    }

    private var isTokenExpired: Bool {
        guard let expirationString = getValue(forKey: tokenExpirationKey) else {
            return false // No expiration means token doesn't expire
        }
        
        let formatter = ISO8601DateFormatter()
        guard let expirationDate = formatter.date(from: expirationString) else {
            return false
        }
        
        return Date() >= expirationDate
    }

    private var pendingHref: String? {
        return getValue(forKey: pendingHrefKey)
    }

    private var isDenied: Bool {
        return getBoolValue(forKey: deniedStateKey)
    }

    private func clearDeniedState() {
        removeValue(forKey: deniedStateKey)
    }

    private func setDeniedState() {
        setBoolValue(true, forKey: deniedStateKey)
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
        #if DEBUG
        print("[SignalKAPIClient] ensureTokenAvailable: currentToken=\(currentToken != nil), isDenied=\(isDenied), pendingHref=\(String(describing: pendingHref))")
        #endif
        // Update published properties on main actor
        defer {
            hasValidToken = currentToken != nil
        }
        if currentToken != nil {
            #if DEBUG
            print("[SignalKAPIClient] ensureTokenAvailable: already have token")
            #endif
            return // Already have valid token
        }
        if isDenied {
            #if DEBUG
            print("[SignalKAPIClient] ensureTokenAvailable: access denied, not retrying")
            #endif
            return // Access was denied, don't retry
        }
        // Check if we have a pending request
        if let href = pendingHref {
            #if DEBUG
            print("[SignalKAPIClient] ensureTokenAvailable: found pendingHref, checking status")
            #endif
            await checkPendingRequest(href: href)
            if currentToken != nil {
                #if DEBUG
                print("[SignalKAPIClient] ensureTokenAvailable: got token after pending check")
                #endif
                return
            }
        }
        // Request new token
        #if DEBUG
        print("[SignalKAPIClient] ensureTokenAvailable: requesting new access token")
        #endif
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
        guard let baseURL = baseURL else {
            #if DEBUG
            print("[SignalKAPIClient] requestNewAccessToken: no baseURL")
            #endif
            return
        }
        #if DEBUG
        print("[SignalKAPIClient] requestNewAccessToken: requesting token for clientId=\(clientId), description=\(description ?? appDisplayName)")
        #endif
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
            #if DEBUG
            print("[SignalKAPIClient] requestNewAccessToken: POST \(url) body=\(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "nil")")
            #endif
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                #if DEBUG
                print("[SignalKAPIClient] requestNewAccessToken: invalid response")
                #endif
                return
            }
            #if DEBUG
            print("[SignalKAPIClient] requestNewAccessToken: status=\(httpResponse.statusCode)")
            #endif
            if httpResponse.statusCode == 501 {
                #if DEBUG
                print("[SignalKAPIClient] requestNewAccessToken: server does not support access requests (501)")
                #endif
                return
            }
            let accessResponse = try JSONDecoder().decode(SignalKAccessResponse.self, from: data)
            if httpResponse.statusCode == 202 || httpResponse.statusCode == 400 {
                // Store href for status checking
                if let href = accessResponse.href {
                    setValue(href, forKey: pendingHrefKey)
                    #if DEBUG
                    print("[SignalKAPIClient] requestNewAccessToken: received href=\(href)")
                    #endif
                    // Check status immediately for 400 responses (existing request)
                    if httpResponse.statusCode == 400 {
                        await checkPendingRequest(href: href)
                    }
                }
            }
        } catch {
            #if DEBUG
            print("[SignalKAPIClient] requestNewAccessToken: error \(error)")
            #endif
            // Handle error silently - token requests are optional
        }
    }
    
    private func checkPendingRequest(href: String) async {
        guard let baseURL = baseURL else {
            #if DEBUG
            print("[SignalKAPIClient] checkPendingRequest: no baseURL")
            #endif
            return
        }
        #if DEBUG
        print("[SignalKAPIClient] checkPendingRequest: href=\(href)")
        #endif
        do {
            let url = baseURL.appendingPathComponent(href)
            let request = URLRequest(url: url)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                #if DEBUG
                print("[SignalKAPIClient] checkPendingRequest: invalid response or status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                #endif
                return
            }
            let status = try JSONDecoder().decode(SignalKAccessStatus.self, from: data)
            #if DEBUG
            print("[SignalKAPIClient] checkPendingRequest: state=\(status.state), permission=\(status.accessRequest?.permission ?? "nil")")
            #endif
            if status.state == "COMPLETED" {
                // Clear pending request
                removeValue(forKey: pendingHrefKey)
                #if DEBUG
                print("[SignalKAPIClient] checkPendingRequest: request completed, cleared href")
                #endif
                if let accessRequest = status.accessRequest {
                    if accessRequest.permission == "APPROVED" {
                        // Store token
                        if let token = accessRequest.token {
                            setValue(token, forKey: tokenKey)
                            // Store expiration if provided
                            if let expirationTime = accessRequest.expirationTime {
                                setValue(expirationTime, forKey: tokenExpirationKey)
                            }
                            clearDeniedState()
                            await MainActor.run {
                                hasValidToken = true
                            }
                            #if DEBUG
                            print("[SignalKAPIClient] checkPendingRequest: token approved and stored")
                            #endif
                        }
                    } else if accessRequest.permission == "DENIED" {
                        // Mark as denied to prevent further requests
                        setDeniedState()
                        #if DEBUG
                        print("[SignalKAPIClient] checkPendingRequest: token denied")
                        #endif
                    }
                }
            }
            // If still PENDING, leave href in place for next check
        } catch {
            #if DEBUG
            print("[SignalKAPIClient] checkPendingRequest: error \(error)")
            #endif
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
