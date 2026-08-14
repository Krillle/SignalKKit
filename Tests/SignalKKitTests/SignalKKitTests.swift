import XCTest
import Combine
import Starscream
@testable import SignalKKit

final class SignalKKitTests: XCTestCase {
    func testAccessAuthorizationStateIsMissingBeforeServerConfiguration() {
        let client = SignalKAPIClient()

        XCTAssertEqual(client.accessAuthorizationState, .missing)
    }

    func testServerScopedStorageKeyIncludesNormalizedHostAndPort() throws {
        let url = try XCTUnwrap(URL(string: "https://SignalK.local:3443"))

        XCTAssertEqual(
            SignalKAPIClient.serverScopedStorageKey(for: "accessToken", baseURL: url),
            "SignalKKit.signalk.local:3443.accessToken"
        )
        XCTAssertEqual(
            SignalKAPIClient.serverScopedStorageKey(for: "pendingHref", baseURL: url),
            "SignalKKit.signalk.local:3443.pendingHref"
        )
        XCTAssertEqual(
            SignalKAPIClient.serverScopedStorageKey(for: "deniedState", baseURL: url),
            "SignalKKit.signalk.local:3443.deniedState"
        )
    }

    func testServerIdentifierUsesDefaultPortWhenURLOmitsPort() throws {
        let httpURL = try XCTUnwrap(URL(string: "http://SIGNALK.local"))
        let httpsURL = try XCTUnwrap(URL(string: "https://SIGNALK.local"))

        XCTAssertEqual(SignalKAPIClient.normalizedServerIdentifier(for: httpURL), "signalk.local:80")
        XCTAssertEqual(SignalKAPIClient.normalizedServerIdentifier(for: httpsURL), "signalk.local:443")
    }

    func testInvalidatingUnauthorizedTokenPreservesClientIdentifier() async throws {
        let client = SignalKAPIClient()
        let host = "unauthorized-\(UUID().uuidString.lowercased()).local"
        let url = try XCTUnwrap(URL(string: "http://\(host):3000"))
        let tokenKey = try XCTUnwrap(
            SignalKAPIClient.serverScopedStorageKey(for: "accessToken", baseURL: url)
        )
        UserDefaults.standard.set("stale-token", forKey: tokenKey)
        defer { UserDefaults.standard.removeObject(forKey: tokenKey) }

        client.setBaseURL(url)
        let clientIdentifier = client.accessRequestClientIdentifier
        XCTAssertEqual(client.accessAuthorizationState, .authorized)

        let invalidatedToken = await client.invalidateStoredAccessTokenIfPresent()
        XCTAssertTrue(invalidatedToken)
        XCTAssertEqual(client.accessAuthorizationState, .missing)
        XCTAssertEqual(client.accessRequestClientIdentifier, clientIdentifier)
    }

    func testPutReportsDeniedAccessInsteadOfMissingToken() async throws {
        let client = SignalKAPIClient()
        let host = "denied-\(UUID().uuidString.lowercased()).local"
        let url = try XCTUnwrap(URL(string: "http://\(host):3000"))
        let deniedStateKey = try XCTUnwrap(
            SignalKAPIClient.serverScopedStorageKey(for: "deniedState", baseURL: url)
        )
        UserDefaults.standard.set(true, forKey: deniedStateKey)
        NSUbiquitousKeyValueStore.default.set(true, forKey: deniedStateKey)
        defer {
            UserDefaults.standard.removeObject(forKey: deniedStateKey)
            NSUbiquitousKeyValueStore.default.removeObject(forKey: deniedStateKey)
        }

        client.setBaseURL(url)
        XCTAssertEqual(client.accessAuthorizationState, .denied)

        do {
            try await client.put(path: "/signalk/v1/api/vessels/self", data: Data())
            XCTFail("Expected denied access to prevent the PUT request")
        } catch SignalKError.accessDenied {
            // Expected.
        } catch {
            XCTFail("Expected accessDenied, received \(error)")
        }
    }

    func testDeltaPublishesValuesOnceWithPerUpdateTimestamps() throws {
        let socket = WebSocketClientStub()
        let client = SignalKClient(socketFactory: { _ in socket })
        client.connect(to: "signalk.local", port: 3000)
        let published = expectation(description: "Published complete delta")
        published.assertForOverFulfill = true
        var publishedValueCount = 0
        var cancellables = Set<AnyCancellable>()

        client.$pathValues
            .dropFirst()
            .sink { values in
                publishedValueCount += 1
                if values.count == 6 {
                    published.fulfill()
                }
            }
            .store(in: &cancellables)

        client.didReceive(
            event: .text(
                """
                {
                  "context": "vessels.self",
                  "updates": [
                    {
                      "timestamp": "2026-07-30T00:00:00.123Z",
                      "values": [
                        { "path": "navigation.headingTrue", "value": 1.25 },
                        { "path": "navigation.speedOverGround", "value": 2.5 }
                      ]
                    },
                    {
                      "timestamp": "2026-07-30T00:00:01Z",
                      "values": [
                        { "path": "environment.water.temperature", "value": 293.15 }
                      ]
                    }
                  ]
                }
                """
            ),
            client: socket
        )

        wait(for: [published], timeout: 1)

        XCTAssertEqual(publishedValueCount, 1)
        XCTAssertEqual(doubleValue(client.pathValues["navigation.headingTrue"]), 1.25)
        XCTAssertEqual(doubleValue(client.pathValues["vessels.self.navigation.headingTrue"]), 1.25)
        XCTAssertEqual(doubleValue(client.pathValues["navigation.speedOverGround"]), 2.5)
        XCTAssertEqual(doubleValue(client.pathValues["vessels.self.navigation.speedOverGround"]), 2.5)
        XCTAssertEqual(doubleValue(client.pathValues["environment.water.temperature"]), 293.15)
        XCTAssertEqual(doubleValue(client.pathValues["vessels.self.environment.water.temperature"]), 293.15)

        let fractionalDate = try XCTUnwrap(
            ISO8601DateFormatter.date(
                from: "2026-07-30T00:00:00.123Z",
                formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            )
        )
        let plainDate = try XCTUnwrap(
            ISO8601DateFormatter.date(
                from: "2026-07-30T00:00:01Z",
                formatOptions: [.withInternetDateTime]
            )
        )
        XCTAssertEqual(client.pathTimestamps["navigation.headingTrue"], fractionalDate)
        XCTAssertEqual(client.pathTimestamps["navigation.speedOverGround"], fractionalDate)
        XCTAssertEqual(client.pathTimestamps["environment.water.temperature"], plainDate)
    }

    func testConnectionDiagnosticsPreserveStarscreamFailureDetails() throws {
        let socket = WebSocketClientStub()
        let client = SignalKClient(socketFactory: { _ in socket })
        client.connect(to: "signalk.local", port: 3000)

        client.didReceive(
            event: .disconnected("Handshake rejected", 1002),
            client: socket
        )
        XCTAssertEqual(
            client.lastConnectionDiagnostic,
            "WebSocket disconnected code=1002 reason=Handshake rejected"
        )

        let error = WSError(
            type: .serverError,
            message: "Upgrade failed",
            code: 400
        )
        client.didReceive(event: .error(error), client: socket)
        XCTAssertEqual(
            client.lastConnectionDiagnostic,
            "WebSocket error type=serverError code=400 description=Upgrade failed"
        )

        client.didReceive(
            event: .error(
                HTTPUpgradeError.notAnUpgrade(
                    302,
                    [
                        "location": "/login",
                        "server": "Signal K",
                        "x-private-header": "must not be logged"
                    ]
                )
            ),
            client: socket
        )
        XCTAssertEqual(
            client.lastConnectionDiagnostic,
            "WebSocket HTTP upgrade rejected status=302 headers=location=/login,server=Signal K"
        )
    }

    func testDesiredSubscriptionsAreReplayedOnEveryNewSocket() throws {
        let factory = WebSocketFactoryStub()
        let client = SignalKClient(socketFactory: factory.makeSocket)
        let subscriptions = [
            SignalKSubscriptionRequest(path: "navigation.position", policy: "instant"),
            SignalKSubscriptionRequest(path: "navigation.headingTrue", policy: "instant")
        ]

        client.subscribe(paths: subscriptions)
        client.connect(to: "signalk.local", port: 3000)
        let firstSocket = try XCTUnwrap(factory.sockets.first)
        firstSocket.emit(.connected([:]))

        XCTAssertEqual(try firstSocket.subscribedPaths(), subscriptions.map(\.path))
        XCTAssertTrue(client.isConnected)

        client.disconnect()
        XCTAssertFalse(client.isConnected)

        client.connect(to: "signalk.local", port: 3000)
        let secondSocket = try XCTUnwrap(factory.sockets.last)
        XCTAssertFalse(firstSocket === secondSocket)
        secondSocket.emit(.connected([:]))

        XCTAssertEqual(try secondSocket.subscribedPaths(), subscriptions.map(\.path))
        XCTAssertTrue(client.isConnected)

        // A delayed callback from the replaced socket must not clobber the new connection.
        client.didReceive(
            event: .disconnected("late old socket callback", 1000),
            client: firstSocket
        )
        XCTAssertTrue(client.isConnected)
        XCTAssertNil(client.lastConnectionDiagnostic)
    }

    func testResubscribingUpdatesDesiredPolicyWithoutDuplicatingPath() throws {
        let factory = WebSocketFactoryStub()
        let client = SignalKClient(socketFactory: factory.makeSocket)

        client.subscribe(paths: [
            SignalKSubscriptionRequest(path: "navigation.position", policy: "fixed", period: 2)
        ])
        client.subscribe(paths: [
            SignalKSubscriptionRequest(path: "navigation.position", policy: "instant")
        ])
        client.connect(to: "signalk.local", port: 3000)
        let socket = try XCTUnwrap(factory.sockets.first)
        socket.emit(.connected([:]))

        let entries = try socket.subscriptionEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["path"] as? String, "navigation.position")
        XCTAssertEqual(entries.first?["policy"] as? String, "instant")
    }

    func testUnsubscribeRemovesPathFromFutureReconnects() throws {
        let factory = WebSocketFactoryStub()
        let client = SignalKClient(socketFactory: factory.makeSocket)

        client.subscribe(paths: [
            SignalKSubscriptionRequest(path: "navigation.position", policy: "instant"),
            SignalKSubscriptionRequest(path: "navigation.headingTrue", policy: "instant")
        ])
        client.connect(to: "signalk.local", port: 3000)
        let firstSocket = try XCTUnwrap(factory.sockets.first)
        firstSocket.emit(.connected([:]))
        client.unsubscribe(paths: ["navigation.position"])

        client.disconnect()
        client.connect(to: "signalk.local", port: 3000)
        let secondSocket = try XCTUnwrap(factory.sockets.last)
        secondSocket.emit(.connected([:]))

        XCTAssertEqual(try secondSocket.subscribedPaths(), ["navigation.headingTrue"])
    }

    private func doubleValue(_ value: CodableValue?) -> Double? {
        value?.doubleValue()
    }
}

private final class WebSocketFactoryStub {
    private(set) var sockets: [WebSocketClientStub] = []

    func makeSocket(request: URLRequest) -> SignalKWebSocket {
        let socket = WebSocketClientStub()
        sockets.append(socket)
        return socket
    }
}

private final class WebSocketClientStub: SignalKWebSocket {
    weak var delegate: WebSocketDelegate?
    private(set) var writtenStrings: [String] = []

    func connect() {}
    func disconnect(closeCode: UInt16) {}
    func write(string: String, completion: (() -> Void)?) {
        writtenStrings.append(string)
        completion?()
    }
    func write(stringData: Data, completion: (() -> Void)?) {}
    func write(data: Data, completion: (() -> Void)?) {}
    func write(ping: Data, completion: (() -> Void)?) {}
    func write(pong: Data, completion: (() -> Void)?) {}

    func emit(_ event: WebSocketEvent) {
        delegate?.didReceive(event: event, client: self)
    }

    func subscriptionEntries() throws -> [[String: Any]] {
        let message = try XCTUnwrap(writtenStrings.last)
        let data = try XCTUnwrap(message.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(dictionary["subscribe"] as? [[String: Any]])
    }

    func subscribedPaths() throws -> [String] {
        try subscriptionEntries().compactMap { $0["path"] as? String }
    }
}

private extension ISO8601DateFormatter {
    static func date(from string: String, formatOptions: Options) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = formatOptions
        return formatter.date(from: string)
    }
}
