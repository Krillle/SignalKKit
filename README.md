# SignalKKit

SignalKKit is a lightweight Swift Package to discover Signal K servers on the local network and consume their real‑time data stream over WebSockets. It also provides a complete HTTP API client with automatic access token management for GET/PUT requests to the Signal K REST API.

It is intentionally generic: your app chooses which Signal K paths to subscribe to and reads values from a flexible dictionary, without the package imposing any fixed model.

## Features

- mDNS/Bonjour discovery for common Signal K service types
- WebSocket client for the Signal K delta stream
- HTTP API client with automatic access token management
- Flexible subscriptions via path strings (no hardcoded paths)
- Generic value store keyed by Signal K paths
- Handles update-level and value-level paths and normalizes with context
- Optional auto-subscribe to all updates for quick start

## Installation

Add the package to your project using Swift Package Manager:

1. In Xcode: File > Add Packages…
2. Enter the repository URL: `https://github.com/Krillle/SignalKKit.git`
3. Choose the latest version and add the `SignalKKit` product to your app target.

Or in `Package.swift`:

```swift
dependencies: [
		.package(url: "https://github.com/Krillle/SignalKKit.git", from: "1.0.0")
]
```

## iOS permissions

Add the following to your app target’s Info.plist:

- `NSLocalNetworkUsageDescription` — e.g. “This app discovers Signal K servers on your local network.”
- `NSBonjourServices` — array including:
	- `_signalk-ws._tcp.`
	- `_signalk-http._tcp.`
	- `_sk._tcp.` (legacy)

## Quick start (SwiftUI)

```swift
import SwiftUI
import SignalKKit

struct ContentView: View {
		@StateObject private var client = SignalKClient()
		@StateObject private var discovery = SignalKDiscovery()

		var body: some View {
				VStack(spacing: 12) {
						Text("SOG: \(speedOverGroundKnots ?? 0, specifier: "%.2f") kn")
						Text("COG: \(courseOverGroundDegrees ?? 0, specifier: "%.1f")°")
						Text("Lat: \(latitude ?? 0, specifier: "%.5f")")
						Text("Lon: \(longitude ?? 0, specifier: "%.5f")")
						Text("Water: \(waterTemperatureCelsius ?? 0, specifier: "%.2f") °C")
				}
				.onAppear { discovery.startBrowsing() }
				.onChange(of: discovery.discoveredServices) { services in
						// Prefer WebSocket service; fall back to legacy _sk._tcp.
						let preferred = services.first { $0.type == "_signalk-ws._tcp." } ?? services.first { $0.type == "_sk._tcp." }
						guard let service = preferred, let host = service.hostName else { return }

						// Optional: manually control subscriptions (auto-subscribe is enabled by default)
						client.subscribe(paths: [
								.init(path: "navigation.position"),
								.init(path: "navigation.courseOverGroundTrue", policy: "instant"),
								.init(path: "navigation.speedOverGround", policy: "instant"),
								.init(path: "environment.water.temperature", policy: "instant")
						])

						client.connect(to: host, port: service.port)
				}
		}

		// MARK: - Derived values from client.pathValues
		private func double(for path: String) -> Double? {
				if case .double(let v)? = client.pathValues[path] { return v }
				if case .int(let i)? = client.pathValues[path] { return Double(i) }
				if case .string(let s)? = client.pathValues[path] { return Double(s) }
				return nil
		}

		private var latitude: Double? {
				if case .dict(let d)? = client.pathValues["navigation.position"] { return d["latitude"] }
				return double(for: "navigation.position.latitude")
		}

		private var longitude: Double? {
				if case .dict(let d)? = client.pathValues["navigation.position"] { return d["longitude"] }
				return double(for: "navigation.position.longitude")
		}

		private var courseOverGroundDegrees: Double? {
				guard let rad = double(for: "navigation.courseOverGroundTrue") else { return nil }
				return rad * 180 / .pi
		}

		private var speedOverGroundKnots: Double? {
				guard let ms = double(for: "navigation.speedOverGround") else { return nil }
				return ms * 1.943_844_49
		}

		private var waterTemperatureCelsius: Double? {
				guard let k = double(for: "environment.water.temperature") else { return nil }
				return k - 273.15
		}
}
```

## API overview

- `SignalKDiscovery`
	- `startBrowsing()` / `stopBrowsing()`
	- `@Published var discoveredServices: [NetService]` — publish services as they are found and resolved

- `SignalKClient`
	- `public init()`
	- `connect(to host: String, port: Int)` / `disconnect()`
	- `@Published public var pathValues: [String: CodableValue]` — all received values keyed by path
	- `subscribe(paths: [SignalKSubscriptionRequest])` — request server subscriptions
	- `unsubscribe(paths: [String])` — cancel subscriptions
	- `subscribeAllOnConnect: Bool` — default true; set false if you want to control all subscriptions
	- `context: String` — default `vessels.self`; used to normalize absolute/relative paths
	- `authToken: String?` — optional bearer token for secured servers
	- `useTLS: Bool?` — set to force `wss`/`ws` (auto-detects by port when nil)
	- `@Published private(set) var isConnected: Bool` — observe connection state
	- `apiClient: SignalKAPIClient` — HTTP API client with automatic token management

- `SignalKAPIClient`
	- `get(path: String) async throws -> Data` — GET requests with automatic token handling
	- `put(path: String, data: Data) async throws` — PUT requests with automatic token management
	- `requestAccessToken(description: String?) async throws` — manual token request
	- `@Published private(set) var hasValidToken: Bool` — observe token availability
	- `@Published private(set) var isTokenRequestPending: Bool` — observe token request status

- `SignalKSubscriptionRequest`
	- `path: String`
	- Optional: `policy` (e.g., `instant`, `fixed`), `period`, `minPeriod`

- `CodableValue` enum
	- Supports numbers, strings, bools, nulls, and simple `[String: Double]` dictionaries
	- Utility: `doubleValue()` tries to coerce to `Double`

## Notes on paths and context

Signal K deltas may include the data path at the update level or the value level. SignalKKit resolves the effective path and stores entries using both absolute (with context prefix) and relative keys so you can look up by either form. Example: if context is `vessels.self` and the value path is `navigation.speedOverGround`, both of these keys will be present:

- `vessels.self.navigation.speedOverGround`
- `navigation.speedOverGround`


## HTTP API and Access Token Usage

SignalKKit provides a built-in HTTP API client for GET and PUT requests to the Signal K REST API, with fully automatic access token management. The app does not need to handle tokens directly.

### Basic Usage

- The API client is available as `client.apiClient` from any `SignalKClient` instance.
- The API client automatically uses the correct base URL and manages tokens for you.

#### GET Example

```swift
let data = try await client.apiClient.get(path: "signalk/v1/api/vessels/self")
```

#### PUT Example (auto token request)

```swift
let jsonData = """{"value": 1.234}""".data(using: .utf8)!
try await client.apiClient.put(path: "signalk/v1/api/vessels/self/navigation/courseOverGroundTrue", data: jsonData)
```

#### On-demand token request

```swift
try await client.apiClient.requestAccessToken(description: "My Marine App")
```

#### Observe token status

```swift
client.apiClient.$hasValidToken.sink { hasToken in
	print("Token available: \(hasToken)")
}
```

### How it works

- The API client uses a persistent UUID as clientId (shared across devices via iCloud/NSUbiquitousKeyValueStore with UserDefaults fallback).
- PUT requests automatically trigger token requests if needed.
- GET requests automatically retry with token acquisition on 401 responses.
- If the server requires approval, the client checks the request status on subsequent API calls and stores the token when approved.
- If access is denied, the client will not retry until the denied state is cleared.
- Tokens are automatically used for both GET and PUT requests when available.
- Revoked/expired tokens are automatically detected and refreshed as needed.

### Notes

- Most servers allow GET without a token, but PUT always requires one.
- The app never needs to manage tokens, request IDs, or approval flows—everything is automatic.
- Token storage works without iCloud entitlements by falling back to local UserDefaults.

---

## Troubleshooting

- Seeing zeros? Confirm your server actually publishes the paths you display. Some servers use `navigation.courseOverGround` instead of `navigation.courseOverGroundTrue`, or alternative environment paths.
- Not receiving anything?
	- Ensure local network and Bonjour permissions are set.
	- Try leaving subscriptions empty; with `subscribeAllOnConnect = true`, the server may push updates without explicit subscribes.
	- If your server uses TLS on a non-standard port, set `client.useTLS = true`.
	- If the server requires auth, set `client.authToken` before `connect`.

## License

MIT
